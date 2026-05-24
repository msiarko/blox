const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const core = @import("core");
const Blockchain = core.Blockchain;
const Block = core.Blockchain.Block;
const Peer = @import("Peer.zig");

const log = std.log.scoped(.state);

const Self = @This();

allocator: std.mem.Allocator,
lock: std.Io.Mutex,
chain: Blockchain,
transaction_pool: core.TransactionPool,
wallet: core.Wallet,
peers: std.StringHashMap(*Peer),
self_peer: Peer,
broadcast_group: std.Io.Group = .init,

pub fn init(
    io: Io,
    allocator: Allocator,
    self_peer: Peer,
    peers: []Peer,
) !Self {
    var self: Self = .{
        .allocator = allocator,
        .lock = .init,
        .chain = try .init(allocator),
        .transaction_pool = .init,
        .wallet = .init(io, null),
        .peers = .init(allocator),
        .self_peer = self_peer,
    };
    errdefer {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.destroy(entry.value_ptr);
        }
        self.peers.deinit();
        self.chain.deinit(allocator);
    }

    var key_buf: [64]u8 = undefined;
    for (peers) |*peer| {
        const tmp_key = try peer.print(&key_buf);
        const owned_key = try self.allocator.dupe(u8, tmp_key);
        errdefer self.allocator.free(owned_key);

        try self.peers.put(owned_key, peer);
    }

    return self;
}

pub fn deinit(self: *Self, io: Io) void {
    self.broadcast_group.cancel(io);

    var it = self.peers.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.destroy(entry.value_ptr);
    }
    self.peers.deinit();
    self.transaction_pool.deinit(self.allocator);
    self.chain.deinit(self.allocator);
}

pub fn printChain(
    self: *Self,
    io: Io,
    writer: *std.Io.Writer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.printJson(writer);
}

pub fn printTransactions(
    self: *Self,
    io: Io,
    writer: *std.Io.Writer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.transaction_pool.printJson(writer);
}

pub fn addPeer(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    var peer_key_buffer: [64]u8 = undefined;
    const peer_key = try peer.print(&peer_key_buffer);

    const owned_key = try self.allocator.dupe(u8, peer_key);
    errdefer self.allocator.free(owned_key);

    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.peers.put(owned_key, peer);
}

pub fn removePeer(
    self: *Self,
    io: Io,
    peer_key: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);

    if (self.peers.fetchRemove(peer_key)) |kv| {
        self.allocator.free(kv.key);
    }
}

pub fn send(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    var allocating = std.Io.Writer.Allocating.init(self.allocator);
    defer allocating.deinit();

    {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try self.chain.printJson(&allocating.writer);
    }

    const json = allocating.written();
    const msg = try self.allocator.dupe(u8, json);
    errdefer self.allocator.free(msg);

    var old: [1][]const u8 = undefined;
    const n = peer.message_queue.get(io, &old, 0) catch 0;
    for (old[0..n]) |stale| self.allocator.free(stale);

    try peer.message_queue.putOne(io, msg);
}

pub fn mine(
    self: *Self,
    io: Io,
    data: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.add(io, self.allocator, data);
}

pub fn replace(
    self: *Self,
    io: Io,
    chain: *const Blockchain,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.replace(self.allocator, chain);
}

pub fn broadcast(self: *Self, io: Io) !void {
    if (self.peers.count() == 0) {
        return;
    }

    var allocating = std.Io.Writer.Allocating.init(self.allocator);
    defer allocating.deinit();

    {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try self.chain.printJson(&allocating.writer);
    }

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    const json = try allocating.toOwnedSlice();
    var it = self.peers.valueIterator();
    while (it.next()) |p| {
        group.async(io, publish, .{ io, p.*, json });
    }
}

fn publish(
    io: std.Io,
    peer: *Peer,
    json: []const u8,
) std.Io.Cancelable!void {
    peer.message_queue.putOne(io, json) catch |err| {
        var buf: [64]u8 = undefined;
        const peer_str = peer.print(&buf) catch "unknown";
        log.warn("Failed to send chain update to peer {s}: {s}", .{ peer_str, @errorName(err) });
        return;
    };
}

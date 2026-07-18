const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Timestamp = Io.Timestamp;
const DefaultPrng = std.Random.DefaultPrng;
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

const core = @import("core");
const Blockchain = core.Blockchain;
const Block = core.Blockchain.Block;
const Peer = @import("Peer.zig");
const p2p = @import("p2p.zig");

const log = std.log.scoped(.state);

const Self = @This();

allocator: Allocator,
lock: Io.Mutex,
chain: Blockchain,
transaction_pool: core.TransactionPool,
rand: std.Random,
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
    var rand = DefaultPrng.init(@intCast(Timestamp.now(io, .real).toMilliseconds()));
    var self: Self = .{
        .allocator = allocator,
        .lock = .init,
        .chain = try .init(allocator),
        .transaction_pool = .init,
        .rand = rand.random(),
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
        entry.value_ptr.*.deinit(io, self.allocator);
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

pub fn createTransaction(
    self: *Self,
    io: std.Io,
    recipient: []const u8,
    amount: f128,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    var buf: [33]u8 = undefined;
    const sec1 = try std.fmt.hexToBytes(&buf, recipient);
    try self.wallet.createTransaction(
        io,
        self.allocator,
        self.rand,
        try ecdsa.PublicKey.fromSec1(sec1),
        amount,
        &self.transaction_pool,
    );
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

pub fn sendToPeer(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    const msg = try self.createBlockchainMessage(io);
    errdefer self.allocator.free(msg);

    try peer.sendMessage(io, self.allocator, msg);
}

pub fn createBlock(
    self: *Self,
    io: Io,
    data: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.add(io, self.allocator, data);
}

pub fn replaceChain(
    self: *Self,
    io: Io,
    chain: *const Blockchain,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.replace(self.allocator, chain);
}

pub fn broadcastChain(self: *Self, io: Io) !void {
    if (self.peers.count() == 0) {
        return;
    }

    const msg = try self.createBlockchainMessage(io);
    errdefer self.allocator.free(msg);

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    var it = self.peers.valueIterator();
    while (it.next()) |peer_ptr| {
        group.async(io, publish, .{ io, self.allocator, peer_ptr.*, msg });
    }

    try group.await(io);
}

fn createBlockchainMessage(self: *Self, io: Io) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(self.allocator);
    defer allocating.deinit();

    try allocating.writer.print("{{\"type\": {d}, \"data\": ", .{p2p.MessageType.blockchain});
    {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try self.chain.printJson(&allocating.writer);
    }

    try allocating.writer.print("}}", .{});
    return allocating.toOwnedSlice();
}

fn publish(
    io: std.Io,
    allocator: Allocator,
    peer: *Peer,
    msg: []const u8,
) std.Io.Cancelable!void {
    peer.sendMessage(io, allocator, msg) catch return error.Canceled;
}

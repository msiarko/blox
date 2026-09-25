const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.network);

const Peer = @import("../Peer.zig");
const Blockchain = @import("Blockchain.zig");
const Block = @import("Block.zig");
const MessageType = @import("../p2p.zig").MessageType;

pub const Network = struct {
    const Self = @This();

    self_peer: Peer,
    peers: std.StringHashMap(Peer),
    allocator: Allocator,

    pub fn init(allocator: Allocator, self_peer: Peer, known_peers: []const Peer) !Self {
        var peers = std.StringHashMap(Peer).init(allocator);

        var key_buf: [64]u8 = undefined;

        for (known_peers) |peer| {
            const key = try peer.print(&key_buf);
            const key_dup = try allocator.dupe(u8, key);
            try peers.put(key_dup, peer);
        }

        return .{
            .self_peer = self_peer,
            .peers = peers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self, io: Io) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            var peer = entry.value_ptr;
            peer.deinit(io, self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.peers.deinit();
        self.self_peer.deinit(io, self.allocator);
    }

    pub fn createPeer(self: *Self, io: Io, address: []const u8) !void {
        var peer = try Peer.parse(self.allocator, address);
        errdefer peer.deinit(io, self.allocator);
        
        try self.addPeer(io, &peer);
        
        var peer_key_buffer: [64]u8 = undefined;
        const peer_key = try peer.print(&peer_key_buffer);
        
        log.info("Peer {s} added", .{peer_key});
    }

    pub fn addPeer(self: *Self, io: Io, peer: *Peer) !void {
        var key_buf: [64]u8 = undefined;
        const key = try peer.print(&key_buf);

        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);
        
        if (try self.peers.fetchPut(key_dup, peer.*)) |old| {
            var old_peer = old.value;
            old_peer.deinit(io, self.allocator);
            self.allocator.free(key_dup);
        }
    }

    pub fn removePeer(self: *Self, io: Io, key: []const u8) !void {
        if (self.peers.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var peer = kv.value;
            peer.deinit(io, self.allocator);
        }
    }

    fn publish(io: std.Io, allocator: Allocator, peer: *Peer, msg: []const u8) std.Io.Cancelable!void {
        peer.sendMessage(io, allocator, msg) catch return error.Canceled;
    }

    pub fn sendToPeer(self: *Self, io: Io, peer: *Peer, chain: *const Blockchain) !void {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        try allocating.writer.print("{{\"type\": {d}, \"data\": ", .{MessageType.blockchain});
        var stringify: std.json.Stringify = .{ .writer = &allocating.writer, .options = .{} };
        try stringify.write(chain);
        try allocating.writer.print("}}", .{});
        
        const msg = allocating.written();
        try peer.sendMessage(io, self.allocator, msg);
    }

    pub fn broadcastChain(self: *Self, io: Io, chain: *const Blockchain) !void {
        if (self.peers.count() == 0) return;

        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        try allocating.writer.print("{{\"type\": {d}, \"data\": ", .{MessageType.blockchain});
        var stringify: std.json.Stringify = .{ .writer = &allocating.writer, .options = .{} };
        try stringify.write(chain);
        try allocating.writer.print("}}", .{});
        
        const msg = try allocating.toOwnedSlice();
        defer self.allocator.free(msg);

        var group: std.Io.Group = .init;
        errdefer group.cancel(io);
        var it = self.peers.valueIterator();
        while (it.next()) |peer_ptr| group.async(io, publish, .{ io, self.allocator, peer_ptr, msg });
        try group.await(io);
    }

    pub fn broadcastNewBlock(self: *Self, io: Io, block: *const Block) !void {
        if (self.peers.count() == 0) return;

        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        try allocating.writer.print("{{\"type\": {d}, \"data\": ", .{MessageType.new_block});
        var stringify: std.json.Stringify = .{ .writer = &allocating.writer, .options = .{} };
        try stringify.write(block);
        try allocating.writer.print("}}", .{});
        
        const msg = try allocating.toOwnedSlice();
        defer self.allocator.free(msg);

        var group: std.Io.Group = .init;
        errdefer group.cancel(io);
        var it = self.peers.valueIterator();
        while (it.next()) |peer_ptr| group.async(io, publish, .{ io, self.allocator, peer_ptr, msg });
        try group.await(io);
    }

    pub fn broadcastRequestChain(self: *Self, io: Io) !void {
        if (self.peers.count() == 0) return;

        const msg = try std.fmt.allocPrint(self.allocator, "{{\"type\": {d}}}", .{MessageType.request_chain});
        defer self.allocator.free(msg);

        var group: std.Io.Group = .init;
        errdefer group.cancel(io);
        var it = self.peers.valueIterator();
        while (it.next()) |peer_ptr| group.async(io, publish, .{ io, self.allocator, peer_ptr, msg });
        try group.await(io);
    }
};

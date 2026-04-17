const std = @import("std");
const Io = std.Io;

const core = @import("core");

const Peer = @import("peer.zig").Peer;

pub const MAX_PEERS_COUNT: usize = 64;

pub const AppState = struct {
    const Self = @This();

    lock: std.Io.Mutex,
    chain: core.Blockchain,
    peers: std.StringHashMap(*Peer),
    self_peer: Peer,

    pub fn init(allocator: std.mem.Allocator, self_peer: Peer, peers: []Peer) !Self {
        var self: Self = .{
            .lock = .init,
            .chain = try .init(allocator),
            .peers = .init(allocator),
            .self_peer = self_peer,
        };
        errdefer self.chain.deinit(allocator);
        errdefer {
            var it = self.peers.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*.buffer);
                allocator.free(entry.value_ptr.*.uri_string);
                allocator.destroy(entry.value_ptr.*);
            }
            self.peers.deinit();
        }

        var key_buf: [128]u8 = undefined;
        for (peers) |peer| {
            const peer_ptr = try allocator.create(Peer);
            peer_ptr.* = peer;
            errdefer {
                allocator.free(peer_ptr.*.buffer);
                allocator.free(peer_ptr.*.uri_string);
                allocator.destroy(peer_ptr);
            }

            const tmp_key = try peer_ptr.print(&key_buf);
            const owned_key = try allocator.dupe(u8, tmp_key);
            errdefer allocator.free(owned_key);

            try self.peers.put(owned_key, peer_ptr);
        }

        return self;
    }

    pub fn deinit(self: *Self, io: Io, allocator: std.mem.Allocator) void {
        self.self_peer.deinit(io, allocator);

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(io, allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        self.peers.deinit();
        self.chain.deinit(allocator);
    }

    pub fn getChainJson(self: *Self, io: Io, writer: *std.Io.Writer) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try self.chain.json(writer);
    }

    pub fn addPeer(
        self: *Self,
        io: Io,
        allocator: std.mem.Allocator,
        peer_key: []const u8,
        peer: Peer,
    ) !*Peer {
        const owned_key = try allocator.dupe(u8, peer_key);
        errdefer allocator.free(owned_key);

        const peer_ptr = try allocator.create(Peer);
        errdefer allocator.destroy(peer_ptr);
        peer_ptr.* = peer;

        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try self.peers.put(owned_key, peer_ptr);
        return peer_ptr;
    }

    pub fn removePeer(
        self: *Self,
        io: Io,
        allocator: std.mem.Allocator,
        peer_key: []const u8,
    ) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);

        if (self.peers.fetchRemove(peer_key)) |kv| {
            allocator.free(kv.key);
            kv.value.deinit(io, allocator);
            allocator.destroy(kv.value);
        }
    }

    pub fn sendChainToPeer(self: *Self, io: Io, allocator: std.mem.Allocator, peer: *Peer) !void {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        defer allocating.deinit();

        {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            try self.chain.json(&allocating.writer);
        }

        const json = allocating.written();
        const msg = try allocator.dupe(u8, json);
        errdefer allocator.free(msg);

        var old: [1][]const u8 = undefined;
        const n = peer.message_queue.get(io, &old, 0) catch 0;
        for (old[0..n]) |stale| allocator.free(stale);

        try peer.message_queue.putOne(io, msg);
    }

    pub fn addBlock(self: *Self, io: Io, allocator: std.mem.Allocator, data: []const u8) !void {
        const last_hash = blk: {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            break :blk try self.chain.getLastHash();
        };

        const new_item = try core.Block.init(io, allocator, &last_hash, data);

        try self.lock.lock(io);
        defer self.lock.unlock(io);
        return self.chain.add(allocator, new_item);
    }

    pub fn replaceChain(self: *Self, io: Io, allocator: std.mem.Allocator, chain: *const core.Blockchain) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        return self.chain.replace(allocator, chain);
    }

    pub fn broadcastChain(self: *Self, io: Io, allocator: std.mem.Allocator) !void {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        defer allocating.deinit();

        var queue_buf: [MAX_PEERS_COUNT]*Io.Queue([]const u8) = undefined;
        var queue_count: usize = 0;

        {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            try self.chain.json(&allocating.writer);
            var it = self.peers.valueIterator();
            while (it.next()) |peer_ptr| {
                if (queue_count < queue_buf.len) {
                    queue_buf[queue_count] = &peer_ptr.*.message_queue;
                    queue_count += 1;
                } else {
                    std.log.warn("broadcastChain: peer count exceeds max_peers ({d}), skipping remaining", .{MAX_PEERS_COUNT});
                    break;
                }
            }
        }

        const json = allocating.written();
        for (queue_buf[0..queue_count]) |queue| {
            var old: [1][]const u8 = undefined;
            const n = queue.get(io, &old, 0) catch 0;
            for (old[0..n]) |stale| allocator.free(stale);

            const msg = allocator.dupe(u8, json) catch continue;
            queue.putOne(io, msg) catch allocator.free(msg);
        }
    }
};

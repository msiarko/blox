const std = @import("std");
const Io = std.Io;
const core = @import("core");
const Peer = @import("peer.zig").Peer;

pub const AppState = struct {
    const Self = @This();

    lock: std.Io.Mutex,
    chain: core.Blockchain,
    /// Peers are heap-allocated (*Peer) so their address (and the address of
    /// their message_queue) stays stable across hashmap resizes.
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
        // Free any peers already inserted into the map on error.
        // We can't call Peer.deinit (needs Io) here, so we free the backing
        // allocations manually – no async tasks are running during init so the
        // queue has no waiters and its buffer just needs to be released.
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

    /// Heap-allocates `peer` and inserts it into the peers map.
    /// Returns a stable *Peer pointer valid until removePeer or deinit.
    /// The caller must NOT call peer.deinit() after a successful call –
    /// ownership is transferred.
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

    /// Serialises the current chain and enqueues it directly into one peer's
    /// message queue so the peer syncs on every (re)connect.
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

        // Discard any pending snapshot — only the latest state matters.
        var old: [1][]const u8 = undefined;
        const n = peer.message_queue.get(io, &old, 0) catch 0;
        for (old[0..n]) |stale| allocator.free(stale);

        try peer.message_queue.putOne(io, msg);
    }

    /// Returns a snapshot of all current *Peer pointers (held under lock).
    /// The pointers themselves remain valid (heap-allocated) until removePeer
    /// or deinit. The caller must free the returned slice with allocator.free().
    pub fn getPeerPtrs(self: *Self, io: Io, allocator: std.mem.Allocator) ![]*Peer {
        try self.lock.lock(io);
        defer self.lock.unlock(io);

        var list: std.ArrayList(*Peer) = .empty;
        errdefer list.deinit(allocator);

        var it = self.peers.valueIterator();
        while (it.next()) |ptr| {
            try list.append(allocator, ptr.*);
        }
        return list.toOwnedSlice(allocator);
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

        var queues: std.ArrayList(*Io.Queue([]const u8)) = .empty;
        defer queues.deinit(allocator);

        {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            try self.chain.json(&allocating.writer);
            var it = self.peers.valueIterator();
            while (it.next()) |peer_ptr| {
                // peer_ptr.* is *Peer (stable heap address); take address of its queue.
                try queues.append(allocator, &peer_ptr.*.message_queue);
            }
        }

        const json = allocating.written();
        for (queues.items) |queue| {
            // Discard any pending snapshot — only the latest state matters.
            var old: [1][]const u8 = undefined;
            const n = queue.get(io, &old, 0) catch 0;
            for (old[0..n]) |stale| allocator.free(stale);

            const msg = allocator.dupe(u8, json) catch continue;
            queue.putOne(io, msg) catch allocator.free(msg);
        }
    }
};

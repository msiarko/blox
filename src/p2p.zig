const std = @import("std");
const Io = std.Io;

const core = @import("core");

const Peer = @import("peer.zig").Peer;
const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const MAX_PEERS_COUNT = state_mod.MAX_PEERS_COUNT;

pub const ClientWebSocket = struct {
    const Self = @This();

    input: *Io.Reader,
    output: *Io.Writer,
    mask: [4]u8,

    pub const Opcode = enum(u4) {
        text = 1,
        binary = 2,
        connection_close = 8,
        ping = 9,
        pong = 10,
        _,
    };

    pub const Message = struct {
        opcode: Opcode,
        data: []const u8,
    };

    pub fn init(io: Io, input: *Io.Reader, output: *Io.Writer) Self {
        var mask_key: [4]u8 = undefined;
        var default_rng = std.Random.DefaultPrng.init(@intCast(Io.Timestamp.now(io, .real).toMicroseconds()));
        var random = default_rng.random();
        random.bytes(&mask_key);

        return .{
            .input = input,
            .output = output,
            .mask = mask_key,
        };
    }

    pub fn writeMessage(self: *Self, data: []const u8, opcode: Opcode) !void {
        try self.output.writeAll(&.{0x80 | @as(u8, @intFromEnum(opcode))});

        if (data.len < 126) {
            try self.output.writeAll(&.{0x80 | @as(u8, @intCast(data.len))});
        } else if (data.len <= 0xFFFF) {
            var buf: [3]u8 = undefined;
            buf[0] = 0x80 | 126;
            std.mem.writeInt(u16, buf[1..3], @intCast(data.len), .big);
            try self.output.writeAll(&buf);
        } else {
            var buf: [9]u8 = undefined;
            buf[0] = 0x80 | 127;
            std.mem.writeInt(u64, buf[1..9], @intCast(data.len), .big);
            try self.output.writeAll(&buf);
        }

        try self.output.writeAll(&self.mask);

        var i: usize = 0;
        while (i < data.len) {
            const end = @min(i + 1024, data.len);
            var chunk: [1024]u8 = undefined;
            for (i..end) |j| chunk[j - i] = data[j] ^ self.mask[j % 4];
            try self.output.writeAll(chunk[0 .. end - i]);
            i = end;
        }
    }

    pub fn flush(self: *Self) !void {
        try self.output.flush();
    }

    pub fn readSmallMessage(self: *Self, buf: []u8) !Message {
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        const opcode: Opcode = @enumFromInt(header[0] & 0x0F);
        const is_masked = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
        }

        var mask_key: [4]u8 = undefined;
        if (is_masked) try self.readExact(&mask_key);

        if (payload_len > buf.len) return error.MessageTooLarge;
        const payload = buf[0..payload_len];
        try self.readExact(payload);

        if (is_masked) {
            for (payload, 0..) |*b, i| b.* ^= mask_key[i % 4];
        }

        return .{ .opcode = opcode, .data = payload };
    }

    fn readExact(self: *Self, buf: []u8) !void {
        var writer = Io.Writer.fixed(buf);
        try self.input.streamExact(&writer, buf.len);
    }
};

pub fn connectWebSocket(
    io: Io,
    state: *AppState,
    peer: *Peer,
    reader: *Io.net.Stream.Reader,
    writer: *Io.net.Stream.Writer,
) !ClientWebSocket {
    var key_bytes: [16]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(@intCast(Io.Timestamp.now(io, .real).toMicroseconds()));
    rng.random().bytes(&key_bytes);
    var key_buf: [std.base64.standard.Encoder.calcSize(16)]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

    var host_buf: [128]u8 = undefined;
    const host_header = try peer.print(&host_buf);
    const blox_peer_uri = state.self_peer.uri_string;
    const path_raw = switch (peer.uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };
    const path = if (path_raw.len == 0) "/ws" else path_raw;

    var handshake_buf: [512]u8 = undefined;
    const handshake = try std.fmt.bufPrint(
        &handshake_buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Blox-Peer-Uri: {s}\r\n\r\n",
        .{ path, host_header, key, blox_peer_uri },
    );

    try writer.interface.writeAll(handshake);
    try writer.interface.flush();

    var got101 = false;
    while (true) {
        const line = try reader.interface.takeDelimiter('\n');
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n");
            if (trimmed.len == 0) break;
            if (std.mem.startsWith(u8, trimmed, "HTTP/1.1 101")) got101 = true;
        } else break;
    }
    if (!got101) return error.WebSocketUpgradeFailed;

    return .init(io, &reader.interface, &writer.interface);
}

pub const BlockJson = struct {
    prev_hash: []const u8,
    hash: []const u8,
    timestamp: i64,
    nonce: u64,
    data: []const u8,

    pub fn toBlock(self: *const BlockJson) !core.Block {
        var prev_hash: core.Hash = undefined;
        var hash: core.Hash = undefined;

        _ = try std.fmt.hexToBytes(&prev_hash, self.prev_hash);
        _ = try std.fmt.hexToBytes(&hash, self.hash);

        return .{
            .prev_hash = prev_hash,
            .hash = hash,
            .timestamp = self.timestamp,
            .nonce = self.nonce,
            .data = self.data,
        };
    }
};

pub fn applyChainUpdate(
    io: Io,
    allocator: std.mem.Allocator,
    state: *AppState,
    json: []const u8,
) !void {
    const parsed = std.json.parseFromSlice([]const BlockJson, allocator, json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Received unparseable chain ({s}), ignoring", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    var blocks = try std.ArrayList(core.Block).initCapacity(allocator, parsed.value.len);

    var blocks_owned = false;
    defer if (!blocks_owned) {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    };

    for (parsed.value) |item| {
        const b = item.toBlock() catch |err| {
            std.log.warn("Peer sent block with invalid fields ({s}), ignoring chain", .{@errorName(err)});
            return; // defer above handles cleanup
        };
        const owned_data = try allocator.dupe(u8, b.data);
        blocks.appendAssumeCapacity(.{
            .timestamp = b.timestamp,
            .prev_hash = b.prev_hash,
            .hash = b.hash,
            .nonce = b.nonce,
            .data = owned_data,
        });
    }

    var new_chain: core.Blockchain = .{ .blocks = blocks };
    blocks_owned = true;
    defer new_chain.deinit(allocator);

    state.replaceChain(io, allocator, &new_chain) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.info("Did not replace chain ({s})", .{@errorName(err)});
        return;
    };
    std.log.info("Chain replaced from peer update", .{});
}

pub fn sendToPeer(
    io: Io,
    allocator: std.mem.Allocator,
    peer: *Peer,
    msg: []const u8,
) !void {
    const copy = try allocator.dupe(u8, msg);
    errdefer allocator.free(copy);
    try peer.message_queue.putOne(io, copy);
}

pub fn connectToPeers(
    io: Io,
    allocator: std.mem.Allocator,
    state: *AppState,
) !void {
    var connections: Io.Group = .init;
    defer connections.cancel(io);

    var peer_buf: [MAX_PEERS_COUNT]*Peer = undefined;
    var peer_count: usize = 0;
    {
        try state.lock.lock(io);
        defer state.lock.unlock(io);
        var it = state.peers.valueIterator();
        while (it.next()) |ptr| {
            if (peer_count < peer_buf.len) {
                peer_buf[peer_count] = ptr.*;
                peer_count += 1;
            } else {
                std.log.warn("connectToPeers: peer count exceeds max_peers ({d}), extra peers skipped", .{MAX_PEERS_COUNT});
                break;
            }
        }
    }

    for (peer_buf[0..peer_count]) |peer_ptr| {
        connections.async(io, subscribeChainUpdates, .{ io, allocator, state, peer_ptr });
    }

    try state.broadcastChain(io, allocator);
    return connections.await(io);
}

fn subscribeChainUpdates(
    io: Io,
    allocator: std.mem.Allocator,
    state: *AppState,
    peer: *Peer,
) Io.Cancelable!void {
    var delay_ms: i64 = 1_000;
    while (true) {
        const session_ok = blk: {
            runPeerSession(io, allocator, state, peer) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return error.Canceled,
                else => {
                    const host = peer.getHost() catch return error.Canceled;
                    const port = peer.getPort();
                    std.log.warn(
                        "Peer {s}:{d} session ended ({s}), reconnecting in {d} ms",
                        .{ host, port, @errorName(err), delay_ms },
                    );
                    break :blk false;
                },
            };
            break :blk true;
        };

        if (session_ok) delay_ms = 1_000;
        Io.sleep(io, Io.Duration.fromMilliseconds(delay_ms), .real) catch return error.Canceled;
        delay_ms = @min(delay_ms * 2, 30_000);
    }
}

fn runPeerSession(
    io: Io,
    allocator: std.mem.Allocator,
    state: *AppState,
    peer: *Peer,
) !void {
    const address = try peer.getAddress();
    var stream = address.connect(io, .{ .mode = .stream }) catch |err| {
        const host = peer.getHost() catch return err;
        std.log.warn("Cannot connect to {s}:{d}: {s}", .{ host, peer.getPort(), @errorName(err) });
        return err;
    };
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    var ws = try connectWebSocket(io, state, peer, &reader, &writer);

    {
        var drain_buf: [1][]const u8 = undefined;
        const drained = peer.message_queue.get(io, &drain_buf, 0) catch 0;
        for (drain_buf[0..drained]) |stale| allocator.free(stale);
    }

    var broadcast_task = io.async(broadcastClientChainUpdates, .{ io, allocator, &peer.message_queue, &ws });
    defer broadcast_task.cancel(io) catch {};

    try state.sendChainToPeer(io, allocator, peer);

    const msg_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(msg_buf);

    while (true) {
        const msg = try ws.readSmallMessage(msg_buf);
        switch (msg.opcode) {
            .text => {
                var buf: [128]u8 = undefined;
                const peer_key = peer.print(&buf) catch "unknown";
                std.log.info("Received chain update from peer {s}", .{peer_key});
                try applyChainUpdate(io, allocator, state, msg.data);
            },
            .connection_close => {
                var buf: [128]u8 = undefined;
                const peer_key = peer.print(&buf) catch "unknown";
                std.log.info("Peer {s} closed the connection gracefully, will reconnect", .{peer_key});
                return;
            },
            else => continue,
        }
    }
}

fn broadcastClientChainUpdates(
    io: Io,
    allocator: std.mem.Allocator,
    updates_queue: *Io.Queue([]const u8),
    ws: *ClientWebSocket,
) !void {
    while (true) {
        const update = try updates_queue.getOne(io);
        defer allocator.free(update);
        try ws.writeMessage(update, .text);
        try ws.flush();
    }
}

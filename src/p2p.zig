const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const PublicKey = ecdsa.PublicKey;
const Signature = ecdsa.Signature;

const core = @import("core");
const Blockchain = core.Blockchain;
const Block = core.Blockchain.Block;

const Peer = @import("Peer.zig");
const AppState = @import("routes.zig").AppState;

const log = std.log.scoped(.p2p);

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

    pub fn init(
        io: Io,
        input: *Io.Reader,
        output: *Io.Writer,
    ) Self {
        var mask_key: [4]u8 = undefined;
        var default_rng = DefaultPrng.init(
            @intCast(Io.Timestamp.now(io, .real).toMicroseconds()),
        );
        var random = default_rng.random();
        random.bytes(&mask_key);

        return .{
            .input = input,
            .output = output,
            .mask = mask_key,
        };
    }

    pub fn writeMessage(
        self: *Self,
        data: []const u8,
        opcode: Opcode,
    ) !void {
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

    pub fn connect(
        io: Io,
        state: AppState,
        peer: *Peer,
        reader: *Io.net.Stream.Reader,
        writer: *Io.net.Stream.Writer,
    ) !Self {
        var key_bytes: [16]u8 = undefined;
        var rng = DefaultPrng.init(
            @intCast(Io.Timestamp.now(io, .real).toMicroseconds()),
        );
        rng.random().bytes(&key_bytes);
        var key_buf: [std.base64.standard.Encoder.calcSize(16)]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

        var host_buf: [128]u8 = undefined;
        const host_header = try peer.print(&host_buf);

        var uri_buf: [128]u8 = undefined;
        var fixed_writer = Io.Writer.fixed(&uri_buf);
        try state.self_peer.uri.format(&fixed_writer);
        const blox_peer_uri = fixed_writer.buffered();
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

pub fn update(
    io: Io,
    allocator: Allocator,
    state: AppState,
    json: []const u8,
) !void {
    var payload = try std.json.parseFromSlice(
        Payload,
        allocator,
        json,
        .{
            .allocate = .alloc_always,
            .max_value_len = json.len,
        },
    );
    defer payload.deinit();
    switch (payload.value.type) {
        .blockchain => {
            const blocks: []Block = try allocator.alloc(Block, payload.value.data.len);
            defer allocator.free(blocks);

            for (payload.value.data, blocks) |*item, *block| {
                block.* = item.toBlock() catch |err| {
                    log.warn("Peer sent block with invalid fields ({s}), ignoring chain", .{@errorName(err)});
                    return;
                };
            }

            var new_chain: Blockchain = try .fromSlice(allocator, blocks);
            defer new_chain.deinit(allocator);

            state.replaceChain(io, &new_chain) catch |err| {
                if (err == error.OutOfMemory) return err;
                log.info("Did not replace chain ({s})", .{@errorName(err)});
                return;
            };
            log.info("Chain replaced from peer update", .{});
        },
        .transaction => return error.ToDo,
    }
}

pub fn connectAll(
    io: Io,
    allocator: Allocator,
    state: AppState,
) !void {
    if (state.peers.count() == 0) {
        return;
    }

    var peer_connections: Io.Group = .init;
    defer peer_connections.cancel(io);

    {
        try state.lock.lock(io);
        defer state.lock.unlock(io);
        var it = state.peers.valueIterator();
        while (it.next()) |ptr| {
            try peer_connections.concurrent(io, connect, .{ io, allocator, state, ptr.* });
        }
    }

    try state.broadcastChain(io);
    return peer_connections.await(io);
}

fn connect(
    io: Io,
    allocator: Allocator,
    state: AppState,
    peer: *Peer,
) Io.Cancelable!void {
    var delay_ms: i64 = 1_000;
    while (true) {
        const session_ok = blk: {
            startPeerSession(io, allocator, state, peer) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return error.Canceled,
                else => {
                    const host = peer.getHost() catch return error.Canceled;
                    const port = peer.getPort();
                    log.warn(
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

fn startPeerSession(
    io: Io,
    allocator: Allocator,
    state: AppState,
    peer: *Peer,
) !void {
    const address = try peer.getAddress();
    var stream = address.connect(io, .{ .mode = .stream }) catch |err| {
        const host = peer.getHost() catch return err;
        log.warn("Cannot connect to {s}:{d}: {s}", .{ host, peer.getPort(), @errorName(err) });
        return err;
    };
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    var ws = try ClientWebSocket.connect(io, state, peer, &reader, &writer);

    {
        var drain_buf: [1][]const u8 = undefined;
        const drained = peer.message_queue.get(io, &drain_buf, 0) catch 0;
        for (drain_buf[0..drained]) |stale| allocator.free(stale);
    }
    defer ws.flush() catch {};

    var publish_task = try io.concurrent(publish, .{ io, allocator, &peer.message_queue, &ws });
    defer publish_task.cancel(io) catch {};

    try state.sendToPeer(io, peer);

    const msg_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(msg_buf);

    while (true) {
        const msg = try ws.readSmallMessage(msg_buf);
        switch (msg.opcode) {
            .text => {
                var buf: [128]u8 = undefined;
                const peer_key = peer.print(&buf) catch "unknown";
                log.info("Received chain update from peer {s}", .{peer_key});
                try update(io, allocator, state, msg.data);
            },
            .connection_close => {
                var buf: [128]u8 = undefined;
                const peer_key = peer.print(&buf) catch "unknown";
                log.info("Peer {s} closed the connection gracefully, will reconnect", .{peer_key});
                return;
            },
            else => continue,
        }
    }
}

fn publish(
    io: Io,
    allocator: Allocator,
    updates_queue: *Io.Queue([]const u8),
    ws: *ClientWebSocket,
) !void {
    while (true) {
        const msg = try updates_queue.getOne(io);
        defer allocator.free(msg);
        try ws.writeMessage(msg, .text);
        try ws.flush();
    }
}

pub const BlockJson = struct {
    prev_hash: []const u8,
    hash: []const u8,
    timestamp: i64,
    nonce: u64,
    difficulty: u4,
    data: []const u8,

    pub fn toBlock(self: *const BlockJson) !Block {
        var prev_hash: Block.Hash = undefined;
        var hash: Block.Hash = undefined;

        _ = try std.fmt.hexToBytes(&prev_hash, self.prev_hash);
        _ = try std.fmt.hexToBytes(&hash, self.hash);

        return .{
            .prev_hash = prev_hash,
            .hash = hash,
            .timestamp = self.timestamp,
            .nonce = self.nonce,
            .difficulty = self.difficulty,
            .data = self.data,
        };
    }
};

pub const TransactionJson = struct {
    const Input = struct {
        timestamp: i64,
        amount: f128,
        address: [PublicKey.compressed_sec1_encoded_length]u8,
        signature: [Signature.encoded_length]u8,
    };

    const Output = struct {
        amount: f128,
        address: [PublicKey.compressed_sec1_encoded_length]u8,
    };

    id: [core.uuid.length]u8,
    input: Input,
    outputs: []const Output,
};

pub const MessageType = enum {
    blockchain,
    transaction,
};

const Payload = struct {
    type: MessageType,
    data: []const BlockJson,
};

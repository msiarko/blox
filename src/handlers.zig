const std = @import("std");
const WebSocket = std.http.Server.WebSocket;

const core = @import("core");
const volt = @import("volt");

const AppState = @import("state.zig").AppState;
const p = @import("peer.zig");
const p2p = @import("p2p.zig");

pub fn webSockets(ctx: volt.Context, state: *AppState, ws: volt.extract.WebSocket, peer_uri_header: volt.extract.Header("Blox-Peer-Uri")) !volt.Response {
    const peer_uri = peer_uri_header.value orelse {
        return .text(ctx.request_allocator, .bad_request, "Missing Blox-Peer-Uri header", null);
    };

    try ws.onConnected(handleWebSocket, .{ ctx, state, peer_uri });
    return ws.intoResponse();
}

fn handleWebSocket(ctx: volt.Context, state: *AppState, peer_uri: []const u8, ws: *WebSocket) !void {
    var peer: p.Peer = try p.parse(ctx.server_allocator, peer_uri);
    var peer_key_buffer: [128]u8 = undefined;
    const peer_key = peer.print(&peer_key_buffer) catch |err| {
        peer.deinit(ctx.io, ctx.server_allocator);
        return err;
    };

    const peer_ptr = state.addPeer(ctx.io, ctx.server_allocator, peer_key, peer) catch |err| {
        peer.deinit(ctx.io, ctx.server_allocator);
        return err;
    };
    defer state.removePeer(ctx.io, ctx.server_allocator, peer_key) catch {};

    // peer_ptr is heap-allocated (*Peer) – stable across any future hashmap resizes.
    var broadcast_task = ctx.io.async(broadcastChainUpdates, .{ ctx.io, ctx.server_allocator, &peer_ptr.message_queue, ws });
    defer broadcast_task.cancel(ctx.io) catch {};

    try state.broadcastChain(ctx.io, ctx.server_allocator);

    while (true) {
        const msg = try ws.readSmallMessage();
        switch (msg.opcode) {
            .text => {
                std.log.info("Received chain update from inbound peer {s}", .{peer_key});
                try p2p.applyChainUpdate(ctx.io, ctx.server_allocator, state, msg.data);
            },
            .connection_close => {
                std.log.info("Peer {s} closed the connection", .{peer_key});
                break;
            },
            else => continue,
        }
    }
}

fn broadcastChainUpdates(
    io: std.Io,
    allocator: std.mem.Allocator,
    peer_queue: *std.Io.Queue([]const u8),
    ws: *WebSocket,
) !void {
    while (true) {
        const update = try peer_queue.getOne(io);
        defer allocator.free(update);
        try ws.writeMessage(update, .text);
        try ws.flush();
    }
}

pub fn blocks(ctx: volt.Context, state: *AppState) !volt.Response {
    var writer = std.Io.Writer.Allocating.init(ctx.request_allocator);
    try state.getChainJson(ctx.io, &writer.writer);
    const content = writer.written();
    return .json(ctx.request_allocator, .ok, content, null);
}

pub fn mine(ctx: volt.Context, state: *AppState, mine_request: volt.extract.Json(MineRequest)) !volt.Response {
    const payload = mine_request.result catch |err| {
        if (isMemberOfErrorSet(std.json.ParseError(std.json.Scanner), err) and
            !isMemberOfErrorSet(std.mem.Allocator.Error, err))
        {
            return .text(ctx.request_allocator, .bad_request, @errorName(err), null);
        }

        return .text(ctx.request_allocator, .internal_server_error, @errorName(err), null);
    };

    // `server_allocator` required — the mined Block's `data` is appended to the
    // persistent chain and must not be tied to the lifetime of this HTTP request.
    try state.addBlock(ctx.io, ctx.server_allocator, payload.data);
    try state.broadcastChain(ctx.io, ctx.server_allocator);
    return .ok(ctx.request_allocator, "Block mined successfully", null);
}

pub fn isMemberOfErrorSet(comptime T: type, err: anyerror) bool {
    const info = @typeInfo(T);
    if (info != .error_set) @compileError("T should be an error set");

    const error_set = info.error_set orelse return false;
    inline for (error_set) |err_field| {
        if (err == @field(T, err_field.name)) return true;
    }
    return false;
}

const MineRequest = struct {
    data: []u8,
};

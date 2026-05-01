const std = @import("std");
const WebSocket = std.http.Server.WebSocket;

const core = @import("core");
const volt = @import("volt");

const State = @import("State.zig");
const Peer = @import("Peer.zig");
const p2p = @import("p2p.zig");

pub const AppState = *State;

const Router = volt.Router(AppState);

pub fn router(allocator: std.mem.Allocator, state: AppState) !Router {
    var r: Router = .init(allocator, state);
    errdefer r.deinit(allocator);

    try r.get(allocator, "/ws", &webSockets);
    try r.get(allocator, "/blocks", &blocks);
    try r.post(allocator, "/mine", &mine);

    return r;
}

fn webSockets(ctx: volt.Context, state: AppState, peer_uri_header: volt.extract.Header("Blox-Peer-Uri")) !volt.Response {
    const peer_uri = peer_uri_header.value orelse {
        return .text(ctx.req_arena, .bad_request, "Missing Blox-Peer-Uri header", null);
    };

    var ws = try volt.extract.WebSocket.init(ctx);
    defer ws.flush() catch {};

    var peer = try Peer.parse(state.allocator, peer_uri);
    defer peer.deinit(ctx.io, state.allocator);

    try state.addPeer(ctx.io, &peer);
    var peer_key_buffer: [64]u8 = undefined;
    const peer_key = try peer.print(&peer_key_buffer);
    defer state.removePeer(ctx.io, peer_key) catch {};

    std.log.info("Peer {s} connected", .{peer_key});
    var sub_task = ctx.io.async(subscribe, .{ ctx.io, state.allocator, &peer.message_queue, &ws });
    defer sub_task.cancel(ctx.io) catch {};

    try state.broadcast(ctx.io);

    while (true) {
        const msg = ws.readSmallMessage() catch |err| {
            switch (err) {
                WebSocket.ReadSmallTextMessageError.ConnectionClose => std.log.info("Peer {s} disconnected", .{peer_key}),
                else => std.log.warn("Error reading message from peer {s}: {s}", .{ peer_key, @errorName(err) }),
            }
            break;
        };
        switch (msg.opcode) {
            .text => {
                std.log.info("Received chain update from inbound peer {s}", .{peer_key});
                try p2p.update(ctx.io, state.allocator, state, msg.data);
            },
            else => continue,
        }
    }

    return .empty;
}

fn subscribe(
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

fn blocks(ctx: volt.Context, state: AppState) !volt.Response {
    var writer = std.Io.Writer.Allocating.init(ctx.req_arena);
    try state.printChain(ctx.io, &writer.writer);
    const content = writer.written();
    return .json(ctx.req_arena, .ok, content, null);
}

fn mine(ctx: volt.Context, state: AppState, mine_request: volt.extract.Json(MineRequest)) !volt.Response {
    const payload = mine_request.result catch |err| {
        if (isMemberOfErrorSet(std.json.ParseError(std.json.Scanner), err) and
            !isMemberOfErrorSet(std.mem.Allocator.Error, err))
        {
            return .text(ctx.req_arena, .bad_request, @errorName(err), null);
        }

        return .text(ctx.req_arena, .internal_server_error, @errorName(err), null);
    };

    // `server_allocator` required — the mined Block's `data` is appended to the
    // persistent chain and must not be tied to the lifetime of this HTTP request.
    try state.mine(ctx.io, payload.data);
    try state.broadcast(ctx.io);
    return .ok(ctx.req_arena, "Block mined successfully", null);
}

fn isMemberOfErrorSet(comptime T: type, err: anyerror) bool {
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

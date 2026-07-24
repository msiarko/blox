const std = @import("std");
const WebSocket = std.http.Server.WebSocket;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const volt = @import("volt");

const State = @import("State.zig");
const Peer = @import("Peer.zig");
const p2p = @import("p2p.zig");
const WebSocketExtractor = volt.extract.WebSocket;

const log = std.log.scoped(.routes);

pub const AppState = *State;

const Router = volt.Router(AppState);

pub fn router(allocator: Allocator, state: AppState) !Router {
    var r: Router = .init(allocator, state);
    errdefer r.deinit(allocator);

    try r.get(allocator, "/ws", webSockets);
    try r.get(allocator, "/blocks", blocks);
    try r.get(allocator, "/transactions", transactions);
    try r.post(allocator, "/transactions", createTransaction);
    try r.post(allocator, "/blocks", createBlock);

    return r;
}

fn webSockets(
    ctx: volt.Context,
    state: AppState,
    peer_uri_header: volt.extract.Header("Blox-Peer-Uri"),
) !volt.Response {
    const peer_uri = peer_uri_header.value orelse {
        return .text(ctx.req_arena, .bad_request, "Missing Blox-Peer-Uri header", null);
    };

    const ws_ext = WebSocketExtractor.fromContext(ctx);
    var ws = ws_ext.result catch |err| return .text(ctx.req_arena, .internal_server_error, @errorName(err), null);
    defer ws.flush() catch {};

    var peer = try Peer.parse(state.allocator, peer_uri);
    defer peer.deinit(ctx.io, state.allocator);

    try state.addPeer(ctx.io, &peer);
    var peer_key_buffer: [64]u8 = undefined;
    const peer_key = try peer.print(&peer_key_buffer);
    defer state.removePeer(ctx.io, peer_key) catch {};

    log.info("Peer {s} connected", .{peer_key});
    var sub_task = try ctx.io.concurrent(subscribe, .{
        ctx.io,
        state.allocator,
        &peer.message_queue,
        &ws,
    });
    defer sub_task.cancel(ctx.io) catch {};

    try state.broadcastChain(ctx.io);

    while (true) {
        const msg = ws.readSmallMessage() catch |err| {
            switch (err) {
                WebSocket.ReadSmallTextMessageError.ConnectionClose => {
                    log.info("Peer {s} disconnected", .{peer_key});
                },
                else => log.warn("Error reading message from peer {s}: {s}", .{ peer_key, @errorName(err) }),
            }
            break;
        };
        switch (msg.opcode) {
            .text => {
                log.info("Received chain update from inbound peer {s}", .{peer_key});
                try p2p.update(ctx.io, state.allocator, state, msg.data);
            },
            else => continue,
        }
    }

    return .empty;
}

fn subscribe(
    io: Io,
    allocator: Allocator,
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

fn createBlock(
    ctx: volt.Context,
    state: AppState,
    mine_request: volt.extract.Json(MineRequest),
) !volt.Response {
    const payload = mine_request.result catch |err| {
        if (isMemberOfErrorSet(std.json.ParseError(std.json.Scanner), err) and
            !isMemberOfErrorSet(std.mem.Allocator.Error, err))
        {
            return .text(ctx.req_arena, .bad_request, @errorName(err), null);
        }

        return .text(ctx.req_arena, .internal_server_error, @errorName(err), null);
    };

    try state.createBlock(ctx.io, payload.data);
    try state.broadcastChain(ctx.io);
    return .ok(ctx.req_arena, "Block mined successfully", null);
}

fn transactions(ctx: volt.Context, state: AppState) !volt.Response {
    var writer = std.Io.Writer.Allocating.init(ctx.req_arena);
    try state.printTransactions(ctx.io, &writer.writer);
    const content = writer.written();
    return .json(ctx.req_arena, .ok, content, null);
}

fn createTransaction(
    ctx: volt.Context,
    state: AppState,
    transaction_request: volt.extract.Json(TransactionRequest),
) !volt.Response {
    const payload = transaction_request.result catch |err| {
        if (isMemberOfErrorSet(std.json.ParseError(std.json.Scanner), err) and
            !isMemberOfErrorSet(std.mem.Allocator.Error, err))
        {
            return .text(ctx.req_arena, .bad_request, @errorName(err), null);
        }

        return .text(ctx.req_arena, .internal_server_error, @errorName(err), null);
    };

    state.createTransaction(ctx.io, payload.recipient, payload.amount) catch |err| {
        if (err == error.AmountExceedsBalance) return .text(ctx.req_arena, .unprocessable_entity, @errorName(err), null);
        return .text(ctx.req_arena, .internal_server_error, @errorName(err), null);
    };

    return .ok(ctx.req_arena, "Transaction created successfully", null);
}

fn isMemberOfErrorSet(comptime T: type, err: anyerror) bool {
    const info = @typeInfo(T);
    if (info != .error_set) @compileError("T should be an error set");

    const error_names = info.error_set.error_names orelse return false;
    inline for (error_names) |error_name| {
        if (err == @field(T, error_name)) return true;
    }
    return false;
}

const MineRequest = struct {
    data: []u8,
};

const TransactionRequest = struct {
    recipient: []u8,
    amount: f128,
};

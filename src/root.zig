const std = @import("std");
const Io = std.Io;
const IpAddress = std.Io.net.IpAddress;
const WebSocket = std.http.Server.WebSocket;

const core = @import("core");
const volt = @import("volt");
const extractors = volt.extractors;

pub const AppState = struct {
    lock: std.Io.Mutex,
    chain: core.Blockchain,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{ .lock = .init, .chain = try .init(allocator) };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.chain.deinit(allocator);
    }
};

const Server = volt.Server(AppState);

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var state: AppState = try .init(allocator);
    defer state.deinit(allocator);
    var server: Server = try .init(allocator, io, state);
    try server.router.get("/ws", &webSockets);
    try server.router.get("/blocks", &blocks);
    try server.router.post("/mine", &mine);
    defer server.deinit();

    const address: IpAddress = try .parse("127.0.0.1", 8080);
    try server.listen(address, .{});
}

fn webSockets(ctx: volt.Context, state: *AppState, ws: extractors.WebSocket) !volt.Response {
    try ws.onConnected(handleWebSocket, .{ ctx, state });
    return ws.intoResponse();
}

fn handleWebSocket(ctx: volt.Context, state: *AppState, ws: *WebSocket) !void {
    while (true) {
        const msg = try ws.readSmallMessage();
        switch (msg.opcode) {
            .text => {
                const parsed = std.json.parseFromSlice([]const BlockJson, ctx.request_allocator, msg.data, .{}) catch |err| {
                    try ws.writeMessage(@errorName(err), .text);
                    continue;
                };
                defer parsed.deinit();

                const parsed_blocks: []core.Blockchain.Item = try ctx.request_allocator.alloc(core.Blockchain.Item, parsed.value.len);
                defer ctx.request_allocator.free(parsed_blocks);

                for (parsed.value, 0..) |item, i| {
                    parsed_blocks[i] = try item.toBlock();
                }

                const new_chain: core.Blockchain = try .fromSlice(ctx.request_allocator, parsed_blocks);

                try state.lock.lock(ctx.io);
                defer state.lock.unlock(ctx.io);

                state.chain.replace(ctx.server_allocator, &new_chain) catch |err| {
                    try ws.writeMessage(@errorName(err), .text);
                    continue;
                };
                try ws.writeMessage("Chain replaced", .text);
            },
            .connection_close => break,
            else => continue,
        }
    }
}

fn blocks(ctx: volt.Context, state: *AppState) !volt.Response {
    var writer = std.Io.Writer.Allocating.init(ctx.request_allocator);
    try state.lock.lock(ctx.io);
    defer state.lock.unlock(ctx.io);

    try state.chain.json(&writer.writer);
    const content = writer.written();
    return .json(ctx.request_allocator, .ok, content, null);
}

fn mine(ctx: volt.Context, state: *AppState, mine_request: extractors.Json(MineRequest)) !volt.Response {
    try state.lock.lock(ctx.io);
    defer state.lock.unlock(ctx.io);

    const payload = try mine_request.value;
    try state.chain.add(ctx.io, ctx.server_allocator, payload.data);
    return .ok(ctx.request_allocator, "Block mined successfully", null);
}

const MineRequest = struct {
    data: []u8,
};

const BlockJson = struct {
    prev_hash: []const u8,
    hash: []const u8,
    timestamp: i64,
    nonce: u64,
    data: []const u8,

    pub fn toBlock(self: *const @This()) !core.Blockchain.Item {
        var prev_hash: [core.DIGEST_SIZE]u8 = undefined;
        var hash: [core.DIGEST_SIZE]u8 = undefined;

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

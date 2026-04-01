const std = @import("std");
const Io = std.Io;

const core = @import("core");
const web = @import("web");

pub const AppState = struct {
    lock: std.Io.Mutex,
    chain: core.Blockchain,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .lock = .init,
            .chain = try .init(allocator),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.chain.deinit(allocator);
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, app_state: *AppState) !void {
    var server: web.Server(AppState) = .init(allocator, io, app_state);

    try server.router.get("/blocks", handleBlocks);
    try server.router.post("/mine", handleMine);

    defer server.deinit();

    try server.listen(8080);
}

fn handleBlocks(ctx: *web.Context(AppState), req: web.Request) !void {
    var writer = std.Io.Writer.Allocating.init(req.allocator);
    defer writer.deinit();

    try ctx.state.lock.lock(ctx.io);
    defer ctx.state.lock.unlock(ctx.io);

    try ctx.state.chain.json(&writer.writer);
    const content = writer.written();
    try req.http_req.respond(content, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
}

fn handleMine(ctx: *web.Context(AppState), req: web.Request) !void {
    const transfer_buffer = try req.allocator.alloc(u8, req.http_req.head.content_length.?);
    defer req.allocator.free(transfer_buffer);

    const reader = req.http_req.server.reader.bodyReader(
        transfer_buffer,
        req.http_req.head.transfer_encoding,
        req.http_req.head.content_length,
    );

    const data = try reader.readAlloc(req.allocator, req.http_req.head.content_length.?);
    defer req.allocator.free(data);

    const mine_req = try std.json.parseFromSlice(MineRequest, req.allocator, data, .{});
    defer mine_req.deinit();

    try ctx.state.lock.lock(ctx.io);
    defer ctx.state.lock.unlock(ctx.io);

    try ctx.state.chain.add(ctx.io, ctx.allocator, mine_req.value.data);
    try req.http_req.respond("Block mined successfully", .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    });
}

const MineRequest = struct {
    data: []u8,
};

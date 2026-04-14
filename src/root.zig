const std = @import("std");
const volt = @import("volt");
const Environ = std.process.Environ;
const IpAddress = std.Io.net.IpAddress;

const AppState = @import("state.zig").AppState;
const p2p = @import("p2p.zig");
const handlers = @import("handlers.zig");
const env = @import("env.zig");
const peer = @import("peer.zig");

const Server = volt.Server(AppState);

pub fn run(io: std.Io, allocator: std.mem.Allocator, env_map: *Environ.Map) !void {
    var env_arena = std.heap.ArenaAllocator.init(allocator);
    defer env_arena.deinit();

    try env.setupEnv(io, env_arena.allocator(), env_map);

    const peers = try getPeers(allocator, env_map);
    const http_port = blk: {
        const port = env_map.get("HTTP_PORT") orelse "8080";
        break :blk try std.fmt.parseInt(u16, port, 10);
    };

    const address: IpAddress = try .parse("127.0.0.1", http_port);
    const self_peer = try peer.initFromAddress(allocator, address);

    var state: AppState = try .init(allocator, self_peer, peers);
    defer state.deinit(io, allocator);

    allocator.free(peers);

    var server: Server = try .init(allocator, io, state, .{});
    defer server.deinit();

    try server.router.get("/ws", &handlers.webSockets);
    try server.router.get("/blocks", &handlers.blocks);
    try server.router.post("/mine", &handlers.mine);

    var peer_connections = io.async(p2p.connectToPeers, .{ io, allocator, &state });
    defer peer_connections.cancel(io) catch {};

    try server.listen(address);
}

fn getPeers(allocator: std.mem.Allocator, env_map: *Environ.Map) ![]peer.Peer {
    const peers_str = env_map.get("PEERS") orelse return allocator.alloc(peer.Peer, 0);
    var it = std.mem.splitScalar(u8, peers_str, ',');
    var list: std.ArrayList(peer.Peer) = .empty;
    while (it.next()) |entry| {
        const p = try peer.parse(allocator, entry);
        try list.append(allocator, p);
    }
    return list.toOwnedSlice(allocator);
}

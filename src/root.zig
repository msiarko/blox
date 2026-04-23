const std = @import("std");
const Environ = std.process.Environ;
const IpAddress = std.Io.net.IpAddress;

const volt = @import("volt");

const State = @import("State.zig");
const env = @import("env.zig");
const routes = @import("routes.zig");
const p2p = @import("p2p.zig");
const peer = @import("peer.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, env_map: *Environ.Map) !void {
    var env_arena = std.heap.ArenaAllocator.init(allocator);
    defer env_arena.deinit();

    try env.load(io, env_arena.allocator(), env_map);

    const peers = try getPeers(allocator, env_map);
    const http_port = blk: {
        const port = env_map.get("HTTP_PORT") orelse "8080";
        break :blk try std.fmt.parseInt(u16, port, 10);
    };

    const address: IpAddress = try .parse("127.0.0.1", http_port);
    const self_peer = try peer.initFromAddress(allocator, address);
    var server: volt.Server = try .init(io, .{});

    var state: State = try .init(allocator, self_peer, peers);
    defer state.deinit(io);

    allocator.free(peers);

    var peer_connections = io.async(p2p.connectAll, .{ io, allocator, &state });
    defer peer_connections.cancel(io) catch {};

    var router = try routes.router(allocator, &state);
    defer router.deinit(allocator);

    try server.listen(routes.AppState, allocator, address, &router);
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

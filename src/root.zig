const std = @import("std");
const Environ = std.process.Environ;
const IpAddress = std.Io.net.IpAddress;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const volt = @import("volt");

const State = @import("State.zig");
const env = @import("env.zig");
const routes = @import("routes.zig");
const p2p = @import("p2p.zig");
const Peer = @import("Peer.zig");

pub fn run(io: Io, allocator: Allocator, env_map: *Environ.Map) !void {
    var env_arena = std.heap.ArenaAllocator.init(allocator);
    defer env_arena.deinit();

    try env.load(io, env_arena.allocator(), env_map);
    const peers = try getPeers(allocator, env_map);
    defer allocator.free(peers);

    const http_port = blk: {
        const port = env_map.get("HTTP_PORT") orelse "8080";
        break :blk try std.fmt.parseInt(u16, port, 10);
    };

    const address: IpAddress = try .parse("127.0.0.1", http_port);
    var self_peer = try Peer.initFromAddress(allocator, address);
    defer self_peer.deinit(io, allocator);

    var server: volt.Server = try .init(io, .{});
    var state: State = try .init(allocator, self_peer, peers);
    defer state.deinit(io);

    var peer_connections = io.async(p2p.connectAll, .{ io, allocator, &state });
    defer peer_connections.cancel(io) catch {};

    var router = try routes.router(allocator, &state);
    defer router.deinit(allocator);

    try server.listen(routes.AppState, allocator, address, &router);
}

fn getPeers(allocator: Allocator, env_map: *Environ.Map) ![]Peer {
    const peers_str = env_map.get("PEERS") orelse return allocator.alloc(Peer, 0);
    var it = std.mem.splitScalar(u8, peers_str, ',');
    var list: std.ArrayList(Peer) = try .initCapacity(allocator, 8);
    while (it.next()) |entry| {
        const p = try Peer.parse(allocator, entry);
        try list.append(allocator, p);
    }
    return list.toOwnedSlice(allocator);
}

test {
    const Blockchain = @import("Blockchain.zig");
    const Block = @import("Block.zig");
    _ = std.testing.refAllDecls(Block);
    _ = std.testing.refAllDecls(Blockchain);
}

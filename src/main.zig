const std = @import("std");
const Environ = std.process.Environ;
const IpAddress = std.Io.net.IpAddress;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;

const volt = @import("volt");

const p2p = @import("p2p.zig");
const Peer = @import("Peer.zig");
const routes = @import("routes.zig");
const State = @import("State.zig");

pub fn main(init: std.process.Init) !void {
    var io = init.io;
    var allocator = init.gpa;
    const env = init.environ_map;

    const peers = try getPeers(allocator, env);
    defer allocator.free(peers);

    const http_port = try getPort(env);
    const address: IpAddress = try .parse("127.0.0.1", http_port);
    var self_peer = try Peer.initFromAddress(allocator, address);
    defer self_peer.deinit(io, allocator);

    var server: volt.Server = try .init(io, .{});
    var state: State = try .init(io, allocator, self_peer, peers);
    defer state.deinit(io);

    var peer_connections = try io.concurrent(p2p.connectAll, .{ io, allocator, &state });
    defer peer_connections.cancel(io) catch {};

    var router = try routes.router(allocator, &state);
    defer router.deinit(allocator);

    try server.listen(allocator, address, &router);
}

fn getPort(env: *Environ.Map) !u16 {
    const port = env.get("HTTP_PORT") orelse return error.HttpPortMissing;
    return std.fmt.parseInt(u16, port, 10);
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
    const refAllDecls = @import("std").testing.refAllDecls;
    const Blockchain = @import("core/Blockchain.zig");
    const Wallet = @import("core/Wallet.zig");
    const Transaction = @import("core/Transaction.zig");
    const TransactionPool = @import("core/TransactionPool.zig");

    _ = refAllDecls(Blockchain);
    _ = refAllDecls(Blockchain.Block);
    _ = refAllDecls(Wallet);
    _ = refAllDecls(Transaction);
    _ = refAllDecls(TransactionPool);
    _ = refAllDecls(p2p);
    _ = refAllDecls(Peer);
    _ = refAllDecls(routes);
    _ = refAllDecls(State);
}

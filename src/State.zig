const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Peer = @import("Peer.zig");
const Ledger = @import("core/Ledger.zig").Ledger;
const Network = @import("core/Network.zig").Network;
const log = std.log.scoped(.state);

const Self = @This();

allocator: Allocator,
lock: Io.Mutex,
ledger: Ledger,
network: Network,

pub fn init(
    io: Io,
    allocator: Allocator,
    self_peer: Peer,
    known_peers: []const Peer,
) !Self {
    var ledger = try Ledger.init(io, allocator);
    errdefer ledger.deinit();

    var network = try Network.init(allocator, self_peer, known_peers);
    errdefer network.deinit(io);

    return .{
        .allocator = allocator,
        .lock = .init,
        .ledger = ledger,
        .network = network,
    };
}

pub fn deinit(self: *Self, io: Io) void {
    self.ledger.deinit();
    self.network.deinit(io);
}

pub fn printChain(
    self: *Self,
    io: Io,
    writer: *std.Io.Writer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(&self.ledger.chain);
}

pub fn printTransactions(
    self: *Self,
    io: Io,
    writer: *std.Io.Writer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(&self.ledger.transaction_pool);
}

pub fn createTransaction(
    self: *Self,
    io: Io,
    recipient: []const u8,
    amount: u64,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.ledger.createTransaction(io, recipient, amount);
}

pub fn createPeer(
    self: *Self,
    io: Io,
    address: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.network.createPeer(io, address);
}

pub fn addPeer(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.network.addPeer(io, peer);
}

pub fn removePeer(
    self: *Self,
    io: Io,
    key: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.network.removePeer(io, key);
}

pub fn sendToPeer(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.network.sendToPeer(io, peer, &self.ledger.chain);
}

pub fn mineBlock(
    self: *Self,
    io: Io,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.ledger.mineBlock(io);
}

pub fn replaceChain(
    self: *Self,
    io: Io,
    chain: *const @import("core/Blockchain.zig"),
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.ledger.replaceChain(chain);
}

pub fn broadcastChain(self: *Self, io: Io) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.network.broadcastChain(io, &self.ledger.chain);
}

pub fn appendBlock(
    self: *Self,
    io: Io,
    block: *const @import("core/Block.zig"),
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.ledger.appendBlock(block);
}

pub fn broadcastNewBlock(self: *Self, io: Io) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    const last = try self.ledger.chain.getLastBlock();
    try self.network.broadcastNewBlock(io, &last);
}

pub fn broadcastRequestChain(self: *Self, io: Io) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    try self.network.broadcastRequestChain(io);
}

test "addPeer frees old entry on duplicate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const self_address = try Io.net.IpAddress.parse("127.0.0.1", 8080);
    const self_peer = try Peer.initFromAddress(allocator, self_address);

    var state = try Self.init(io, allocator, self_peer, &[_]Peer{});
    defer state.deinit(io);

    const peer_address = try Io.net.IpAddress.parse("127.0.0.1", 9090);
    var peer = try Peer.initFromAddress(allocator, peer_address);

    try state.addPeer(io, &peer);

    // Add again to test freeing old entry
    var peer2 = try Peer.initFromAddress(allocator, peer_address);
    try state.addPeer(io, &peer2);
}

test "deinit doesn't crash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const self_address = try Io.net.IpAddress.parse("127.0.0.1", 8080);
    const self_peer = try Peer.initFromAddress(allocator, self_address);

    var state = try Self.init(io, allocator, self_peer, &[_]Peer{});

    const peer_address = try Io.net.IpAddress.parse("127.0.0.1", 9090);
    var peer = try Peer.initFromAddress(allocator, peer_address);

    try state.addPeer(io, &peer);

    state.deinit(io);
}

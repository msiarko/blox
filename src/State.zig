const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Timestamp = Io.Timestamp;
const DefaultPrng = std.Random.DefaultPrng;
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

const core = @import("core");
const Blockchain = core.Blockchain;
const Block = core.Blockchain.Block;
const Peer = @import("Peer.zig");
const Transaction = core.Transaction;
const TransactionPool = core.TransactionPool;
const Wallet = core.Wallet;
const p2p = @import("p2p.zig");
const MessageType = p2p.MessageType;

const log = std.log.scoped(.state);

const Self = @This();

allocator: Allocator,
lock: Io.Mutex,
chain: Blockchain,
transaction_pool: TransactionPool,
rand: std.Random,
wallet: core.Wallet,
peers: std.StringHashMap(*Peer),
self_peer: Peer,
broadcast_group: std.Io.Group = .init,

pub fn init(
    io: Io,
    allocator: Allocator,
    self_peer: Peer,
    peers: []Peer,
) !Self {
    var rand = DefaultPrng.init(@intCast(Timestamp.now(io, .real).toMilliseconds()));
    var self: Self = .{
        .allocator = allocator,
        .lock = .init,
        .chain = try .init(allocator),
        .transaction_pool = .init,
        .rand = rand.random(),
        .wallet = .init(io, null),
        .peers = .init(allocator),
        .self_peer = self_peer,
    };
    errdefer {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.peers.deinit();
        self.chain.deinit(allocator);
    }

    var key_buf: [64]u8 = undefined;
    for (peers) |*peer| {
        const tmp_key = try peer.print(&key_buf);
        const owned_key = try self.allocator.dupe(u8, tmp_key);
        errdefer self.allocator.free(owned_key);

        try self.peers.put(owned_key, peer);
    }

    return self;
}

pub fn deinit(self: *Self, io: Io) void {
    self.broadcast_group.cancel(io);

    var it = self.peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.deinit(io, self.allocator);
        self.allocator.free(entry.key_ptr.*);
    }

    self.peers.deinit();
    self.transaction_pool.deinit(self.allocator);
    self.chain.deinit(self.allocator);
}

pub fn printChain(
    self: *Self,
    io: Io,
    writer: *std.Io.Writer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return blockchainJson(&self.chain, writer);
}

pub fn printTransactions(
    self: *Self,
    io: Io,
    writer: *std.Io.Writer,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return transactionPoolJson(&self.transaction_pool, writer);
}

pub fn createTransaction(
    self: *Self,
    io: std.Io,
    recipient: []const u8,
    amount: f128,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    var buf: [33]u8 = undefined;
    const sec1 = try std.fmt.hexToBytes(&buf, recipient);
    try self.wallet.createTransaction(
        io,
        self.allocator,
        self.rand,
        try ecdsa.PublicKey.fromSec1(sec1),
        amount,
        &self.transaction_pool,
    );
}

pub fn addPeer(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    var peer_key_buffer: [64]u8 = undefined;
    const peer_key = try peer.print(&peer_key_buffer);

    const owned_key = try self.allocator.dupe(u8, peer_key);
    errdefer self.allocator.free(owned_key);

    try self.lock.lock(io);
    defer self.lock.unlock(io);
    if (try self.peers.fetchPut(owned_key, peer)) |old| {
        self.allocator.free(old.key);
    }
}

pub fn removePeer(
    self: *Self,
    io: Io,
    peer_key: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);

    if (self.peers.fetchRemove(peer_key)) |kv| {
        self.allocator.free(kv.key);
    }
}

pub fn sendToPeer(
    self: *Self,
    io: Io,
    peer: *Peer,
) !void {
    const msg = try self.createBlockchainMessage(io);
    defer self.allocator.free(msg);

    try peer.sendMessage(io, self.allocator, msg);
}

pub fn createBlock(
    self: *Self,
    io: Io,
    data: []const u8,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.add(io, self.allocator, data);
}

pub fn replaceChain(
    self: *Self,
    io: Io,
    chain: *const Blockchain,
) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    return self.chain.replace(self.allocator, chain);
}

pub fn broadcastChain(self: *Self, io: Io) !void {
    if (self.peers.count() == 0) {
        return;
    }

    const msg = try self.createBlockchainMessage(io);
    defer self.allocator.free(msg);

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    var it = self.peers.valueIterator();
    while (it.next()) |peer_ptr| {
        group.async(io, publish, .{ io, self.allocator, peer_ptr.*, msg });
    }

    try group.await(io);
}

fn createBlockchainMessage(self: *Self, io: Io) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(self.allocator);
    defer allocating.deinit();

    try allocating.writer.print("{{\"type\": {d}, \"data\": ", .{MessageType.blockchain});
    {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try blockchainJson(&self.chain, &allocating.writer);
    }

    try allocating.writer.print("}}", .{});
    return allocating.toOwnedSlice();
}

fn publish(
    io: std.Io,
    allocator: Allocator,
    peer: *Peer,
    msg: []const u8,
) std.Io.Cancelable!void {
    peer.sendMessage(io, allocator, msg) catch return error.Canceled;
}

fn blockchainJson(blockchain: *const Blockchain, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    try stringify.beginArray();
    for (0..blockchain.blocks.len) |i| {
        const b = blockchain.blocks.get(i);
        try blockJson(&b, &stringify);
    }

    try stringify.endArray();
}

fn blockJson(block: *const Block, stringify: *std.json.Stringify) !void {
    try stringify.beginObject();

    try stringify.objectField("timestamp");
    try stringify.write(block.timestamp);

    try stringify.objectField("prev_hash");
    try stringify.write(std.fmt.bytesToHex(block.prev_hash, .lower)[0..]);

    try stringify.objectField("hash");
    try stringify.write(std.fmt.bytesToHex(block.hash, .lower)[0..]);

    try stringify.objectField("nonce");
    try stringify.write(block.nonce);

    try stringify.objectField("difficulty");
    try stringify.write(block.difficulty);

    try stringify.objectField("data");
    try stringify.write(block.data);

    try stringify.endObject();
}

fn transactionPoolJson(pool: *const TransactionPool, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    try stringify.beginArray();
    var it = pool.transactions.valueIterator();
    while (it.next()) |transaction| {
        try transactionJson(transaction, &stringify);
    }

    try stringify.endArray();
}

fn transactionJson(transation: *const Transaction, stringify: *std.json.Stringify) !void {
    try stringify.beginObject();

    try stringify.objectField("id");
    try stringify.write(transation.id);

    try stringify.objectField("input");
    try stringify.beginObject();
    try stringify.objectField("timestamp");
    try stringify.write(transation.input.timestamp);
    try stringify.objectField("amount");
    try stringify.write(transation.input.amount);
    try stringify.objectField("address");
    try stringify.write(std.fmt.bytesToHex(transation.input.address.toCompressedSec1(), .lower));
    try stringify.objectField("signature");
    try stringify.write(std.fmt.bytesToHex(transation.input.signature.toBytes(), .lower));
    try stringify.endObject();

    try stringify.objectField("outputs");
    try stringify.beginArray();
    for (transation.outputs.items) |*o| {
        try stringify.beginObject();
        try stringify.objectField("amount");
        try stringify.write(o.amount);
        try stringify.objectField("address");
        try stringify.write(std.fmt.bytesToHex(o.address.toCompressedSec1(), .lower));
        try stringify.endObject();
    }
    try stringify.endArray();

    try stringify.endObject();
}

fn walletJson(wallet: *const Wallet, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    try stringify.beginObject();

    try stringify.objectField("balance");
    try stringify.print("{d:.2}", .{wallet.balance});

    try stringify.objectField("public_key");
    try stringify.print("\"{x}\"", .{&wallet.public_key.toCompressedSec1()});

    try stringify.endObject();
}

test "walletJson outputs correct JSON" {
    const wallet = Wallet.init(std.testing.io, 123.45);
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try walletJson(&wallet, &writer);
    const json = buffer[0..writer.end];
    const expectedJson = try std.testing.allocator.print(
        "{{\"balance\":123.45,\"public_key\":\"{x}\"}}",
        .{&wallet.public_key.toCompressedSec1()},
    );
    defer std.testing.allocator.free(expectedJson);

    try std.testing.expectEqualStrings(expectedJson, json);
}

test "addPeer frees old entry on duplicate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const self_address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    var self_peer = try Peer.initFromAddress(allocator, self_address);
    defer self_peer.deinit(io, allocator);

    var state = try init(io, allocator, self_peer, &[_]Peer{});
    defer {
        var it = state.peers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        state.peers.clearAndFree(allocator);
        state.deinit(io);
    }

    const peer_address = try std.Io.net.IpAddress.parse("127.0.0.1", 9090);
    var peer1 = try Peer.initFromAddress(allocator, peer_address);
    defer peer1.deinit(io, allocator);

    try state.addPeer(io, &peer1);
    try state.addPeer(io, &peer1);
}

test "State.deinit does'n crash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const self_address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    var self_peer = try Peer.initFromAddress(allocator, self_address);
    defer self_peer.deinit(io, allocator);

    var state = try init(io, allocator, self_peer, &[_]Peer{});

    const peer_address = try std.Io.net.IpAddress.parse("127.0.0.1", 9090);
    var peer1 = try Peer.initFromAddress(allocator, peer_address);
    defer peer1.deinit(io, allocator);

    try state.addPeer(io, &peer1);

    state.deinit(io);
}

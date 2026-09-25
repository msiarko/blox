const std = @import("std");
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Transaction = @import("Transaction.zig");
const g = @import("uuid.zig");

const Self = @This();

transactions: std.AutoHashMap(g.Guid, Transaction),
address_index: std.AutoHashMap([33]u8, g.Guid),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .transactions = std.AutoHashMap(g.Guid, Transaction).init(allocator),
        .address_index = std.AutoHashMap([33]u8, g.Guid).init(allocator),
    };
}

pub fn addOrUpdate(self: *Self, allocator: std.mem.Allocator, transaction: Transaction) !void {
    const entry = self.transactions.getEntry(transaction.id);
    if (entry) |e| {
        e.value_ptr.*.deinit(allocator);
        e.value_ptr.* = transaction;
    } else {
        try self.transactions.put(transaction.id, transaction);
    }
    
    const addr = transaction.input.address.toCompressedSec1();
    try self.address_index.put(addr, transaction.id);
}

pub fn getTransaction(self: *const Self, address: ecdsa.PublicKey) ?Transaction {
    const addr = address.toCompressedSec1();
    if (self.address_index.get(addr)) |id| {
        return self.transactions.get(id);
    }
    return null;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    var it = self.transactions.valueIterator();
    while (it.next()) |transaction| {
        transaction.deinit(allocator);
    }
    self.transactions.deinit();
    self.address_index.deinit();
    self.* = undefined;
}

pub fn jsonStringify(self: *const Self, stringify: *std.json.Stringify) !void {
    try stringify.beginArray();
    var it = self.transactions.valueIterator();
    while (it.next()) |transaction| {
        try stringify.write(transaction);
    }
    try stringify.endArray();
}

test "addOrUpdate should add a transaction to the pool" {
    const Wallet = @import("Wallet.zig");
    const Random = std.Random;
    const wallet: Wallet = .init(std.testing.io, 1000);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    const transaction = try Transaction.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );

    var pool: Self = .init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);

    try pool.addOrUpdate(std.testing.allocator, transaction);
    const retrieved = pool.transactions.get(transaction.id).?;
    try std.testing.expectEqual(transaction.id, retrieved.id);
}

test "addOrUpdate should replace an existing transaction with the same ID" {
    const Wallet = @import("Wallet.zig");
    const Random = std.Random;
    const wallet: Wallet = .init(std.testing.io, 1000);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    const transaction1 = try Transaction.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );

    var transaction2 = try Transaction.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        300,
    );

    try std.testing.expect(transaction2.outputs.items[0].amount != transaction1.outputs.items[0].amount);

    // Force transaction2 to have the same ID as transaction1
    transaction2.id = transaction1.id;

    var pool: Self = .init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);

    try pool.addOrUpdate(std.testing.allocator, transaction1);
    try pool.addOrUpdate(std.testing.allocator, transaction2);

    const retrieved = pool.transactions.get(transaction1.id).?;
    try std.testing.expectEqual(transaction2.outputs.items[0].amount, retrieved.outputs.items[0].amount);
}

const std = @import("std");
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Transaction = @import("Transaction.zig");
const g = @import("uuid.zig");

const Self = @This();

transactions: std.AutoHashMapUnmanaged(g.Guid, Transaction),

pub const init: Self = .{ .transactions = .empty };

pub fn addOrUpdate(self: *Self, allocator: std.mem.Allocator, transaction: Transaction) !void {
    const entry = self.transactions.getEntry(transaction.id);
    if (entry) |e| {
        e.value_ptr.*.deinit(allocator);
        e.value_ptr.* = transaction;
        return;
    }

    try self.transactions.put(allocator, transaction.id, transaction);
}

pub fn getTransaction(self: *const Self, address: ecdsa.PublicKey) ?*Transaction {
    const addr = address.toCompressedSec1();
    var it = self.transactions.valueIterator();
    while (it.next()) |transaction| {
        if (std.mem.eql(u8, &transaction.input.address.toCompressedSec1(), &addr)) {
            return transaction;
        }
    }

    return null;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    var it = self.transactions.valueIterator();
    while (it.next()) |transaction| {
        transaction.deinit(allocator);
    }

    self.transactions.deinit(allocator);
    self.* = undefined;
}

test "addOrUpdate should add a transaction to the pool" {
    const Wallet = @import("Wallet.zig");
    const Random = std.Random;
    const wallet: Wallet = .init(std.testing.io, 1000.00);
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

    var pool: Self = .init;
    defer pool.deinit(std.testing.allocator);

    try pool.addOrUpdate(std.testing.allocator, transaction);
    const retrieved = pool.transactions.get(transaction.id).?;
    try std.testing.expectEqual(transaction.id, retrieved.id);
}

test "addOrUpdate should replace an existing transaction with the same ID" {
    const Wallet = @import("Wallet.zig");
    const Random = std.Random;
    const wallet: Wallet = .init(std.testing.io, 1000.00);
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

    var pool: Self = .init;
    defer pool.deinit(std.testing.allocator);

    try pool.addOrUpdate(std.testing.allocator, transaction1);
    try pool.addOrUpdate(std.testing.allocator, transaction2);

    const retrieved = pool.transactions.get(transaction1.id).?;
    try std.testing.expectEqual(transaction2.outputs.items[0].amount, retrieved.outputs.items[0].amount);
}

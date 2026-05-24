const std = @import("std");
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const options = @import("options");
const Transaction = @import("Transaction.zig");
const TransactionPool = @import("TransactionPool.zig");
const h = @import("hash.zig");

const Self = @This();

balance: f128,
key_pair: ecdsa.KeyPair,
public_key: ecdsa.PublicKey,

pub fn init(io: std.Io, balance: ?f128) Self {
    const key_pair = ecdsa.KeyPair.generate(io);
    return .{
        .balance = balance orelse options.initial_balance,
        .key_pair = key_pair,
        .public_key = key_pair.public_key,
    };
}

pub fn sign(self: *const Self, hash: h.Hash) !ecdsa.Signature {
    return try self.key_pair.sign(&hash, null);
}

pub fn createTransaction(
    self: *const Self,
    io: std.Io,
    allocator: std.mem.Allocator,
    rand: std.Random,
    recipient: ecdsa.PublicKey,
    amount: f128,
    transaction_pool: *TransactionPool,
) !void {
    if (amount > self.balance) return error.AmountExceedsBalance;
    const transaction = transaction_pool.getTransaction(self.public_key);
    if (transaction) |tx| {
        try tx.update(
            io,
            allocator,
            self,
            recipient,
            amount,
        );
    } else {
        const tx = try Transaction.init(
            io,
            allocator,
            rand,
            self,
            recipient,
            amount,
        );
        try transaction_pool.addOrUpdate(allocator, tx);
    }
}

pub fn printJson(self: *const Self, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    try stringify.beginObject();

    try stringify.objectField("balance");
    try stringify.print("{d:.2}", .{self.balance});

    try stringify.objectField("public_key");
    try stringify.print("\"{x}\"", .{&self.public_key.toCompressedSec1()});

    try stringify.endObject();
}

test "init without balance sets initial balance" {
    const wallet = Self.init(std.testing.io, null);
    try std.testing.expectEqual(options.initial_balance, wallet.balance);
}

test "init with balance sets balance" {
    const wallet = Self.init(std.testing.io, 100.0);
    try std.testing.expectEqual(100.0, wallet.balance);
}

test "init public key is derived from key pair" {
    const wallet = Self.init(std.testing.io, null);
    try std.testing.expectEqual(wallet.key_pair.public_key, wallet.public_key);
}

test "printJson outputs correct JSON" {
    const wallet = Self.init(std.testing.io, 123.45);
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try wallet.printJson(&writer);
    const json = buffer[0..writer.end];
    const expectedJson = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"balance\":123.45,\"public_key\":\"{x}\"}}",
        .{&wallet.public_key.toCompressedSec1()},
    );
    defer std.testing.allocator.free(expectedJson);

    try std.testing.expectEqualStrings(expectedJson, json);
}

test "createTransaction adds new transaction to pool" {
    const wallet = Self.init(std.testing.io, 1000.0);
    var pool: TransactionPool = .init;
    defer pool.deinit(std.testing.allocator);

    const recipient_key_pair = ecdsa.KeyPair.generate(std.testing.io);
    const recipient_public_key = recipient_key_pair.public_key;

    var default_rand = std.Random.DefaultPrng.init(std.testing.random_seed);
    try wallet.createTransaction(
        std.testing.io,
        std.testing.allocator,
        default_rand.random(),
        recipient_public_key,
        200.0,
        &pool,
    );

    const transaction = pool.getTransaction(wallet.public_key);
    try std.testing.expect(transaction != null);
    try std.testing.expectEqual(200.0, transaction.?.outputs.items[1].amount);
    try std.testing.expectEqualSlices(
        u8,
        &recipient_public_key.toUncompressedSec1(),
        &transaction.?.outputs.items[1].address.toUncompressedSec1(),
    );
}

test "createTransaction updates existing transaction in pool" {
    const wallet = Self.init(std.testing.io, 1000.0);
    var pool: TransactionPool = .init;
    defer pool.deinit(std.testing.allocator);

    const recipient_key_pair = ecdsa.KeyPair.generate(std.testing.io);
    const recipient_public_key = recipient_key_pair.public_key;

    var default_rand = std.Random.DefaultPrng.init(std.testing.random_seed);
    try wallet.createTransaction(
        std.testing.io,
        std.testing.allocator,
        default_rand.random(),
        recipient_public_key,
        200.0,
        &pool,
    );

    var transaction = pool.getTransaction(wallet.public_key);
    try std.testing.expectEqual(2, transaction.?.outputs.items.len);
    try std.testing.expectEqual(800.0, transaction.?.outputs.items[0].amount);

    try wallet.createTransaction(
        std.testing.io,
        std.testing.allocator,
        default_rand.random(),
        recipient_public_key,
        300.0,
        &pool,
    );

    transaction = pool.getTransaction(wallet.public_key);
    try std.testing.expect(transaction != null);
    try std.testing.expectEqual(3, transaction.?.outputs.items.len);
    try std.testing.expectEqual(500.0, transaction.?.outputs.items[0].amount);
    try std.testing.expectEqual(300.0, transaction.?.outputs.items[2].amount);
    try std.testing.expectEqualSlices(
        u8,
        &recipient_public_key.toUncompressedSec1(),
        &transaction.?.outputs.items[2].address.toUncompressedSec1(),
    );
}

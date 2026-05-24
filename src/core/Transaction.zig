const std = @import("std");
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const PublicKey = ecdsa.PublicKey;
const Signature = ecdsa.Signature;
const uuid = @import("uuid.zig");
const Wallet = @import("Wallet.zig");
const Random = std.Random;
const h = @import("hash.zig");

pub const Input = struct {
    timestamp: i64,
    amount: f128,
    address: PublicKey,
    signature: Signature,
};

pub const Output = struct {
    amount: f128,
    address: PublicKey,
};

const Self = @This();

id: uuid.Guid,
input: Input,
outputs: std.ArrayList(Output),

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    rand: Random,
    sender: *const Wallet,
    recipient: PublicKey,
    amount: f128,
) !Self {
    if (amount > sender.balance) return error.AmountExceedsBalance;
    var transaction: Self = .{
        .id = uuid.genV4(rand),
        .input = undefined,
        .outputs = try .initCapacity(allocator, 2),
    };

    transaction.outputs.appendAssumeCapacity(.{
        .amount = sender.balance - amount,
        .address = sender.public_key,
    });
    transaction.outputs.appendAssumeCapacity(.{
        .amount = amount,
        .address = recipient,
    });

    try Self.sign(io, allocator, &transaction, sender);
    return transaction;
}

pub fn verify(self: *const Self, allocator: std.mem.Allocator) !bool {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try self.printOutputs(&allocating.writer);
    const outputs = allocating.written();
    self.input.signature.verify(
        &h.hash(outputs),
        self.input.address,
    ) catch return false;

    return true;
}

pub fn update(
    self: *Self,
    io: std.Io,
    allocator: std.mem.Allocator,
    sender: *const Wallet,
    recipient: PublicKey,
    amount: f128,
) !void {
    if (self.outputs.items.len == 0) return error.NoOutputs;
    const sender_output = blk: {
        for (self.outputs.items) |*o| {
            if (std.mem.eql(
                u8,
                &o.address.toCompressedSec1(),
                &sender.public_key.toCompressedSec1(),
            )) break :blk o;
        }

        break :blk null;
    } orelse return error.SenderOutputNotFound;

    if (amount > sender_output.amount) return error.AmountExceedsBalance;

    sender_output.amount -= amount;
    try self.outputs.append(
        allocator,
        .{ .amount = amount, .address = recipient },
    );
    try Self.sign(io, allocator, self, sender);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.outputs.deinit(allocator);
    self.* = undefined;
}

fn sign(io: std.Io, allocator: std.mem.Allocator, transaction: *Self, sender: *const Wallet) !void {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try transaction.printOutputs(&allocating.writer);
    const outputs = allocating.written();
    transaction.input = .{
        .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .amount = sender.balance,
        .address = sender.public_key,
        .signature = try sender.sign(h.hash(outputs)),
    };
}

fn printOutputs(self: *const Self, writer: *std.Io.Writer) !void {
    for (self.outputs.items) |*o| {
        try writer.printFloat(o.amount, .{ .precision = 2 });
        try writer.printHex(&o.address.toCompressedSec1(), .lower);
    }
}

pub fn jsonStringify(self: *const Self, stringify: *std.json.Stringify) !void {
    try stringify.beginObject();

    try stringify.objectField("id");
    try stringify.write(self.id);

    try stringify.objectField("input");
    try stringify.beginObject();
    try stringify.objectField("timestamp");
    try stringify.write(self.input.timestamp);
    try stringify.objectField("amount");
    try stringify.write(self.input.amount);
    try stringify.objectField("address");
    try stringify.write(std.fmt.bytesToHex(self.input.address.toCompressedSec1(), .lower));
    try stringify.objectField("signature");
    try stringify.write(std.fmt.bytesToHex(self.input.signature.toBytes(), .lower));
    try stringify.endObject();

    try stringify.objectField("outputs");
    try stringify.beginArray();
    for (self.outputs.items) |*o| {
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

test "init returns transaction when amount is less than wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    var transaction = try Self.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );
    defer transaction.deinit(std.testing.allocator);

    try std.testing.expectEqual(800.00, transaction.outputs.items[0].amount);
    try std.testing.expectEqualSlices(
        u8,
        &wallet.public_key.toUncompressedSec1(),
        &transaction.outputs.items[0].address.toUncompressedSec1(),
    );

    try std.testing.expectEqual(200.00, transaction.outputs.items[1].amount);
    try std.testing.expectEqualSlices(
        u8,
        &public_key.toUncompressedSec1(),
        &transaction.outputs.items[1].address.toUncompressedSec1(),
    );
}

test "init returns AmountExceedsBalace error when amount is greater than wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 100);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    const result = Self.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );

    try std.testing.expectError(error.AmountExceedsBalance, result);
}

test "init sets input amount to wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    var transaction = try Self.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );
    defer transaction.deinit(std.testing.allocator);

    try std.testing.expectEqual(1000.00, transaction.input.amount);
}

test "verify returns true for valid transaction" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    var transaction = try Self.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );
    defer transaction.deinit(std.testing.allocator);

    try std.testing.expect(try transaction.verify(std.testing.allocator));
}

test "verify returns false for tampered transaction" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    var transaction = try Self.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        public_key,
        200,
    );
    defer transaction.deinit(std.testing.allocator);

    transaction.outputs.items[0].amount = 900.00;

    try std.testing.expect(!try transaction.verify(std.testing.allocator));
}

test "update modifies outputs and re-signs transaction" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const recipient1 = ecdsa.KeyPair.generate(std.testing.io).public_key;
    const recipient2 = ecdsa.KeyPair.generate(std.testing.io).public_key;

    var transaction = try Self.init(
        std.testing.io,
        std.testing.allocator,
        rand,
        &wallet,
        recipient1,
        200,
    );
    defer transaction.deinit(std.testing.allocator);

    try transaction.update(
        std.testing.io,
        std.testing.allocator,
        &wallet,
        recipient2,
        300,
    );

    try std.testing.expectEqual(500.00, transaction.outputs.items[0].amount);
    try std.testing.expectEqualSlices(
        u8,
        &wallet.public_key.toUncompressedSec1(),
        &transaction.outputs.items[0].address.toUncompressedSec1(),
    );

    try std.testing.expectEqual(200.00, transaction.outputs.items[1].amount);
    try std.testing.expectEqualSlices(
        u8,
        &recipient1.toUncompressedSec1(),
        &transaction.outputs.items[1].address.toUncompressedSec1(),
    );

    try std.testing.expectEqual(300.00, transaction.outputs.items[2].amount);
    try std.testing.expectEqualSlices(
        u8,
        &recipient2.toUncompressedSec1(),
        &transaction.outputs.items[2].address.toUncompressedSec1(),
    );

    try std.testing.expect(try transaction.verify(std.testing.allocator));
}

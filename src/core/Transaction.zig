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
outputs: [2]Output,

pub fn init(
    io: std.Io,
    rand: Random,
    sender: *const Wallet,
    recipient: PublicKey,
    amount: f128,
) !Self {
    if (amount > sender.balance) return error.AmountExceedsBalance;
    var transaction: Self = .{
        .id = uuid.genV4(rand),
        .input = undefined,
        .outputs = .{
            .{ .amount = sender.balance - amount, .address = sender.public_key },
            .{ .amount = amount, .address = recipient },
        },
    };

    try Self.sign(io, &transaction, sender);
    return transaction;
}

fn sign(io: std.Io, transaction: *Self, sender: *const Wallet) !void {
    var buf: [2 * (@sizeOf(f128) + PublicKey.compressed_sec1_encoded_length)]u8 = undefined;
    const outputs = try Self.stringifyOutputs(&buf, transaction);
    transaction.input = .{
        .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .amount = sender.balance,
        .address = sender.public_key,
        .signature = try sender.sign(h.hash(outputs)),
    };
}

fn stringifyOutputs(buffer: []u8, transaction: *const Self) ![]const u8 {
    var fixed = std.Io.Writer.fixed(buffer);
    for (transaction.outputs) |o| {
        try fixed.print("{s}", .{&std.mem.toBytes(o.amount)});
        try fixed.print("{s}", .{&o.address.toCompressedSec1()});
    }
    return buffer[0..fixed.end];
}

test "init returns transaction when amount is less than wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    const transaction = try Self.init(std.testing.io, rand, &wallet, public_key, 200);

    try std.testing.expectEqual(800.00, transaction.outputs[0].amount);
    try std.testing.expectEqualSlices(
        u8,
        &wallet.public_key.toUncompressedSec1(),
        &transaction.outputs[0].address.toUncompressedSec1(),
    );

    try std.testing.expectEqual(200.00, transaction.outputs[1].amount);
    try std.testing.expectEqualSlices(
        u8,
        &public_key.toUncompressedSec1(),
        &transaction.outputs[1].address.toUncompressedSec1(),
    );
}

test "init returns AmountExceedsBalace error when amount is greater than wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 100);
    var default_rand = Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = ecdsa.KeyPair.generate(std.testing.io).public_key;

    const result = Self.init(std.testing.io, rand, &wallet, public_key, 200);
    try std.testing.expectError(error.AmountExceedsBalance, result);
}

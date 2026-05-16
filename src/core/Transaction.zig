const std = @import("std");
const PublicKey = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256.PublicKey;
const uuid = @import("uuid.zig");
const Wallet = @import("Wallet.zig");
const Random = std.Random;

const Output = struct {
    amount: f128,
    address: PublicKey,
};

const Self = @This();

id: [36]u8,
input: void,
outputs: [2]Output,

pub fn init(
    rand: Random,
    sender: *const Wallet,
    recipient: PublicKey,
    amount: f128,
) !Self {
    if (amount > sender.balance) return error.AmountExceedsBalance;

    return .{
        .id = uuid.genV4(rand),
        .input = {},
        .outputs = .{
            .{ .amount = sender.balance - amount, .address = sender.public_key },
            .{ .amount = amount, .address = recipient },
        },
    };
}

test "init returns transaction when amount is less than wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 1000.00);
    var default_rand = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256.KeyPair.generate(std.testing.io).public_key;

    const transaction = try Self.init(rand, &wallet, public_key, 200);

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
    var default_rand = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = default_rand.random();
    const public_key = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256.KeyPair.generate(std.testing.io).public_key;

    const result = Self.init(rand, &wallet, public_key, 200);
    try std.testing.expectError(error.AmountExceedsBalance, result);
}

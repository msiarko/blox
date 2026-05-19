const std = @import("std");
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const options = @import("options");
const Transaction = @import("Transaction.zig");
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

test "public key is derived from key pair" {
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

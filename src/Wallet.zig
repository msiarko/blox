const std = @import("std");
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const options = @import("options");

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

pub fn print(self: *const Self, writer: *std.Io.Writer) !void {
    try writer.print("Wallet {{\r\n\t.balance = {d:.00},\r\n\t.public_key = {x}\r\n}}", .{ self.balance, &self.public_key.toCompressedSec1() });
}

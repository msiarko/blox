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

pub fn printJson(self: *const Self, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    try stringify.beginObject();

    try stringify.objectField("balance");
    try stringify.print("{d:.2}", .{self.balance});

    try stringify.objectField("public_key");
    try stringify.print("{x}", .{&self.public_key.toCompressedSec1()});

    try stringify.endObject();
}

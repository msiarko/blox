const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const PublicKey = ecdsa.PublicKey;
const Signature = ecdsa.Signature;
const uuid = @import("uuid.zig");
const Wallet = @import("Wallet.zig");
const Random = std.Random;
const h = @import("hash.zig");

pub const Input = struct {
    timestamp: i64,
    amount: u64,
    address: PublicKey,
    signature: Signature,
};

pub const Output = struct {
    amount: u64,
    address: PublicKey,
};

pub const Json = struct {
    pub const InputJson = struct {
        timestamp: i64,
        amount: u64,
        address: [PublicKey.compressed_sec1_encoded_length]u8,
        signature: [Signature.encoded_length]u8,
    };

    pub const OutputJson = struct {
        amount: u64,
        address: [PublicKey.compressed_sec1_encoded_length]u8,
    };

    id: [uuid.length]u8,
    input: InputJson,
    outputs: []const OutputJson,

    pub fn toTransaction(self: *const Json, allocator: Allocator) !Self {
        const id = self.id;

        const input = Input{
            .timestamp = self.input.timestamp,
            .amount = self.input.amount,
            .address = try PublicKey.fromSec1(&self.input.address),
            .signature = Signature.fromBytes(self.input.signature),
        };

        var outputs = try std.ArrayList(Output).initCapacity(allocator, self.outputs.len);
        for (self.outputs) |o| {
            outputs.appendAssumeCapacity(.{
                .amount = o.amount,
                .address = try PublicKey.fromSec1(&o.address),
            });
        }

        return .{
            .id = id,
            .input = input,
            .outputs = outputs,
        };
    }
};

const Self = @This();

id: uuid.Guid,
input: Input,
outputs: std.ArrayList(Output),

pub fn init(
    io: Io,
    allocator: Allocator,
    rand: Random,
    sender: *const Wallet,
    recipient: PublicKey,
    amount: u64,
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

pub fn verify(self: *const Self, allocator: Allocator) !bool {
    var allocating: Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try self.printOutputs(&allocating.writer);
    const outputs = allocating.written();
    self.input.signature.verify(
        &h.hash(&.{outputs}),
        self.input.address,
    ) catch return false;

    return true;
}

pub fn update(
    self: *Self,
    io: Io,
    allocator: Allocator,
    sender: *const Wallet,
    recipient: PublicKey,
    amount: u64,
) !void {
    if (self.outputs.items.len == 0) return error.NoOutputs;
    const sender_output = blk: {
        const sender_addr = sender.public_key.toCompressedSec1();
        for (self.outputs.items) |*o| {
            const o_addr = o.address.toCompressedSec1();
            if (std.mem.eql(u8, &o_addr, &sender_addr)) break :blk o;
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

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.outputs.deinit(allocator);
    self.* = undefined;
}

fn sign(io: std.Io, allocator: Allocator, transaction: *Self, sender: *const Wallet) !void {
    var allocating: Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try transaction.printOutputs(&allocating.writer);
    const outputs = allocating.written();
    transaction.input = .{
        .timestamp = Io.Timestamp.now(io, .real).toMilliseconds(),
        .amount = sender.balance,
        .address = sender.public_key,
        .signature = try sender.sign(h.hash(&.{outputs})),
    };
}

fn printOutputs(self: *const Self, writer: *Io.Writer) !void {
    for (self.outputs.items) |*o| {
        try writer.printInt(o.amount, 10, .lower, .{});
        const addr = o.address.toCompressedSec1();
        try writer.printHex(&addr, .lower);
    }
}

pub fn jsonStringify(self: *const Self, stringify: *Stringify) !void {
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
    try stringify.write(std.fmt.bytesToHex(self.input.address.toCompressedSec1(), .lower)[0..]);
    try stringify.objectField("signature");
    try stringify.write(std.fmt.bytesToHex(self.input.signature.toBytes(), .lower)[0..]);
    try stringify.endObject();

    try stringify.objectField("outputs");
    try stringify.beginArray();
    for (self.outputs.items) |*o| {
        try stringify.beginObject();
        try stringify.objectField("amount");
        try stringify.write(o.amount);
        try stringify.objectField("address");
        try stringify.write(std.fmt.bytesToHex(o.address.toCompressedSec1(), .lower)[0..]);
        try stringify.endObject();
    }
    try stringify.endArray();

    try stringify.endObject();
}

test "init returns transaction when amount is less than wallet's balance" {
    const wallet: Wallet = .init(std.testing.io, 1000);
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

    try std.testing.expectEqual(800, transaction.outputs.items[0].amount);
    const wallet_addr = wallet.public_key.toUncompressedSec1();
    const out_addr0 = transaction.outputs.items[0].address.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &wallet_addr, &out_addr0);

    try std.testing.expectEqual(200, transaction.outputs.items[1].amount);
    const pub_addr = public_key.toUncompressedSec1();
    const out_addr1 = transaction.outputs.items[1].address.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &pub_addr, &out_addr1);
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
    const wallet: Wallet = .init(std.testing.io, 1000);
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

    try std.testing.expectEqual(1000, transaction.input.amount);
}

test "verify returns true for valid transaction" {
    const wallet: Wallet = .init(std.testing.io, 1000);
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
    const wallet: Wallet = .init(std.testing.io, 1000);
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

    transaction.outputs.items[0].amount = 900;

    try std.testing.expect(!try transaction.verify(std.testing.allocator));
}

test "update modifies outputs and re-signs transaction" {
    const wallet: Wallet = .init(std.testing.io, 1000);
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

    try std.testing.expectEqual(500, transaction.outputs.items[0].amount);
    const wallet_addr = wallet.public_key.toUncompressedSec1();
    const out_addr0 = transaction.outputs.items[0].address.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &wallet_addr, &out_addr0);

    try std.testing.expectEqual(200, transaction.outputs.items[1].amount);
    const rec1_addr = recipient1.toUncompressedSec1();
    const out_addr1 = transaction.outputs.items[1].address.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &rec1_addr, &out_addr1);

    try std.testing.expectEqual(300, transaction.outputs.items[2].amount);
    const rec2_addr = recipient2.toUncompressedSec1();
    const out_addr2 = transaction.outputs.items[2].address.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &rec2_addr, &out_addr2);

    try std.testing.expect(try transaction.verify(std.testing.allocator));
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Block = @import("Block.zig");
const Hash = Block.Hash;

const Self = @This();

blocks: std.MultiArrayList(Block),

pub fn init(allocator: Allocator) !Self {
    var blocks: std.MultiArrayList(Block) = try .initCapacity(allocator, 8);
    const genesis = try Block.genesis(allocator);
    try blocks.append(allocator, genesis);
    return .{ .blocks = blocks };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (0..self.blocks.len) |i| {
        var b = self.blocks.get(i);
        b.deinit(allocator);
    }

    self.blocks.deinit(allocator);
    self.* = undefined;
}

pub fn add(
    self: *Self,
    io: Io,
    allocator: Allocator,
    data: []const u8,
) !void {
    const prev_block = try self.getLastBlock();
    const block = try Block.init(io, allocator, &prev_block, data);
    try self.blocks.append(allocator, block);
}

pub fn getLastBlock(self: *const Self) !Block {
    if (self.blocks.len == 0) return error.EmptyBlockchain;
    return self.blocks.get(self.blocks.len - 1);
}

fn isValid(self: *const Self) !bool {
    if (self.blocks.len == 0) return false;
    for (1..self.blocks.len) |i| {
        const curr = self.blocks.get(i);
        const prev_hash = self.blocks.items(.hash)[i - 1];
        if (!std.mem.eql(u8, &curr.prev_hash, &prev_hash) or !try curr.isHashValid())
            return false;
    }

    return true;
}

pub fn fromSlice(allocator: Allocator, slice: []const Block) !Self {
    if (slice.len == 0) return error.EmptySlice;
    var blocks: std.MultiArrayList(Block) = try .initCapacity(allocator, slice.len);
    for (slice) |item| {
        try blocks.append(allocator, .{
            .timestamp = item.timestamp,
            .prev_hash = item.prev_hash,
            .hash = item.hash,
            .nonce = item.nonce,
            .difficulty = item.difficulty,
            .data = try allocator.dupe(u8, item.data),
        });
    }

    return .{ .blocks = blocks };
}

pub fn replace(
    self: *Self,
    allocator: Allocator,
    chain: *const Self,
) !void {
    if (self.blocks.len >= chain.blocks.len) return error.ShortBlockchain;
    if (!try chain.isValid()) return error.InvalidChain;
    for (0..self.blocks.len) |i| {
        const self_block = self.blocks.get(i);
        const chain_block = chain.blocks.get(i);
        if (!self_block.eql(&chain_block))
            return error.InvalidChain;
    }

    for (self.blocks.len..chain.blocks.len) |i| {
        const b = &chain.blocks.get(i);
        try self.blocks.append(allocator, .{
            .timestamp = b.timestamp,
            .prev_hash = b.prev_hash,
            .hash = b.hash,
            .nonce = b.nonce,
            .difficulty = b.difficulty,
            .data = try allocator.dupe(u8, b.data),
        });
    }
}

pub fn printJson(self: *const Self, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    try stringify.beginArray();
    for (0..self.blocks.len) |i| {
        const b = self.blocks.get(i);
        try b.jsonStringify(&stringify);
    }

    try stringify.endArray();
}

test "blockchain starts with genesis block" {
    const allocator = std.testing.allocator;
    var genesis_block = try Block.genesis(allocator);
    defer genesis_block.deinit(allocator);

    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    const first_block = &blockchain.blocks.get(0);

    try std.testing.expect(genesis_block.eql(first_block));
}

test "blockchain adds new block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "some data");

    const last_block = try blockchain.getLastBlock();
    try std.testing.expectEqualSlices(u8, "some data", last_block.data);
}

test "blockchain is valid if no data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "some data");
    try std.testing.expect(try blockchain.isValid());
}

test "blockchain is not valid if data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");
    const block = try blockchain.getLastBlock();
    try blockchain.add(io, allocator, "Another data");

    @constCast(block.data)[0] = 'C';

    try std.testing.expect(!try blockchain.isValid());
}

test "blockchain replaces if chain is valid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");
    try blockchain.add(io, allocator, "Another data");

    try initial.replace(allocator, &blockchain);
    try std.testing.expect(initial.blocks.len == blockchain.blocks.len);
}

test "blockchain not replaces if incoming chain is shorter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    try initial.add(io, allocator, "Some data");
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.replace(allocator, &initial);
    try initial.add(io, allocator, "Another data");

    try std.testing.expectError(error.ShortBlockchain, initial.replace(allocator, &blockchain));
}

test "blockchain not replaces if incoming chain is same length" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    try initial.add(io, allocator, "Some data");
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.replace(allocator, &initial);

    try std.testing.expectError(error.ShortBlockchain, initial.replace(allocator, &blockchain));
}

test "blockchain not replaces if incoming chain is invalid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    try initial.add(io, allocator, "Some data");
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.replace(allocator, &initial);
    try blockchain.add(io, allocator, "Another data");

    const last_block = try blockchain.getLastBlock();
    @constCast(last_block.data)[0] = 'C';

    try std.testing.expectError(error.InvalidChain, initial.replace(allocator, &blockchain));
}

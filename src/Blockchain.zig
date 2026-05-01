const std = @import("std");
const builtin = @import("builtin");

const Block = @import("Block.zig");
pub const Hash = Block.Hash;
const json_options: std.json.Stringify.Options = .{
    .whitespace = if (builtin.mode == .Debug) .indent_2 else .minified,
};

const Self = @This();

blocks: std.ArrayList(Block),

pub fn init(allocator: std.mem.Allocator) !Self {
    var blocks: std.ArrayList(Block) = try .initCapacity(allocator, 8);
    const genesis = try Block.genesis(allocator);
    try blocks.append(allocator, genesis);
    return .{ .blocks = blocks };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.blocks.items) |*block| {
        block.deinit(allocator);
    }

    self.blocks.deinit(allocator);
    self.* = undefined;
}

pub fn add(self: *Self, io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
    const prev_block = try self.getLastBlock();
    const block = try Block.init(io, allocator, prev_block, data);
    try self.blocks.append(allocator, block);
}

pub fn getLastBlock(self: *const Self) !*const Block {
    if (self.blocks.items.len == 0)
        return error.BlockchainEmpty;

    return &self.blocks.items[self.blocks.items.len - 1];
}

fn isValid(self: *const Self) bool {
    if (self.blocks.items.len == 0) return false;
    for (1..self.blocks.items.len) |i| {
        const curr = &self.blocks.items[i];
        const prev = &self.blocks.items[i - 1];
        if (!std.mem.eql(u8, &curr.prev_hash, &prev.hash) or !curr.isHashValid())
            return false;
    }

    return true;
}

pub fn fromSlice(allocator: std.mem.Allocator, slice: []const Block) !Self {
    if (slice.len == 0)
        return error.SliceIsEmpty;

    var blocks: std.ArrayList(Block) = .empty;
    for (slice) |item| {
        try blocks.append(allocator, .{
            .timestamp = item.timestamp,
            .prev_hash = item.prev_hash,
            .hash = item.hash,
            .nonce = item.nonce,
            .difficulty = item.difficulty,
            // Each block's `data` is duped into a fresh heap allocation owned by the
            // returned `Blockchain`. The caller is responsible for calling `deinit`.
            .data = try allocator.dupe(u8, item.data),
        });
    }

    return .{ .blocks = blocks };
}

pub fn replace(self: *Self, allocator: std.mem.Allocator, chain: *const Self) !void {
    if (self.blocks.items.len >= chain.blocks.items.len) return error.ChainLengthIsEqualOrLess;
    if (!chain.isValid()) return error.InvalidChain;
    for (self.blocks.items, 0..) |*item, i| {
        if (!item.eql(&chain.blocks.items[i]))
            return error.InvalidChain;
    }

    for (self.blocks.items.len..chain.blocks.items.len) |i| {
        const block = &chain.blocks.items[i];
        try self.blocks.append(allocator, .{
            .timestamp = block.timestamp,
            .prev_hash = block.prev_hash,
            .hash = block.hash,
            .nonce = block.nonce,
            .difficulty = block.difficulty,
            .data = try allocator.dupe(u8, block.data),
        });
    }
}

pub fn printJson(self: *const Self, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = json_options,
    };
    try stringify.write(self.blocks.items);
}

test "blockchain starts with genesis block" {
    const allocator = std.testing.allocator;
    var genesis_block = try Block.genesis(allocator);
    defer genesis_block.deinit(allocator);

    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    const first_block = &blockchain.blocks.items[0];

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
    try std.testing.expect(blockchain.isValid());
}

test "blockchain is not valid if data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");
    const block = try blockchain.getLastBlock();
    try blockchain.add(io, allocator, "Another data");

    const corrupted = try allocator.dupe(u8, "Corrupted");
    allocator.free(block.data);
    @constCast(block).data = corrupted;

    try std.testing.expect(!blockchain.isValid());
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
    try std.testing.expect(initial.blocks.items.len == blockchain.blocks.items.len);
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

    try std.testing.expectError(error.ChainLengthIsEqualOrLess, initial.replace(allocator, &blockchain));
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

    try std.testing.expectError(error.ChainLengthIsEqualOrLess, initial.replace(allocator, &blockchain));
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
    const corrupted = try allocator.dupe(u8, "Corrupted");
    allocator.free(last_block.data);
    @constCast(last_block).data = corrupted;

    try std.testing.expectError(error.InvalidChain, initial.replace(allocator, &blockchain));
}

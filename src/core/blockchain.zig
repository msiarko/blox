const std = @import("std");
const b = @import("block.zig");

pub const Block = b.Block;
pub const Hash = b.Hash;

pub const Blockchain = struct {
    const Self = @This();

    blocks: std.ArrayList(Block),

    pub fn init(allocator: std.mem.Allocator) !Self {
        var blocks: std.ArrayList(Block) = .empty;
        try blocks.append(allocator, b.GENESIS);
        return .{ .blocks = blocks };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.deinit(allocator);
        }

        self.blocks.deinit(allocator);
    }

    pub fn add(self: *Self, allocator: std.mem.Allocator, item: Block) !void {
        if (self.blocks.items.len == 0)
            return error.BlockchainEmpty;

        const prev_block = &self.blocks.items[self.blocks.items.len - 1];
        if (!std.mem.eql(u8, &item.prev_hash, &prev_block.hash))
            return error.InvalidPreviousHash;

        try self.blocks.append(allocator, item);
    }

    fn isValid(self: *const Self) bool {
        if (self.blocks.items.len == 0) return false;

        const genesis = &self.blocks.items[0];
        if (!genesis.eql(&b.GENESIS)) return false;

        for (1..self.blocks.items.len) |i| {
            const curr = &self.blocks.items[i];
            const prev = &self.blocks.items[i - 1];
            if (!std.mem.eql(u8, &curr.prev_hash, &prev.hash) or !curr.isHashValid())
                return false;
        }

        return true;
    }

    pub fn fromSlice(allocator: std.mem.Allocator, slice: []const Block) !Self {
        var blocks: std.ArrayList(Block) = .empty;
        for (slice) |item| {
            try blocks.append(allocator, .{
                .timestamp = item.timestamp,
                .prev_hash = item.prev_hash,
                .hash = item.hash,
                .nonce = item.nonce,
                .data = try allocator.dupe(u8, item.data),
            });
        }

        return .{ .blocks = blocks };
    }

    pub fn getLastHash(self: *const Self) !Hash {
        if (self.blocks.items.len == 0) return error.BlockchainEmpty;
        return self.blocks.items[self.blocks.items.len - 1].hash;
    }

    pub fn replace(self: *Self, allocator: std.mem.Allocator, chain: *const Self) !void {
        if (self.blocks.items.len >= chain.blocks.items.len) return error.ChainLengthIsEqualOrLess;
        if (!chain.isValid()) return error.InvalidChain;

        for (self.blocks.items.len..chain.blocks.items.len) |i| {
            const block = &chain.blocks.items[i];
            try self.blocks.append(allocator, .{
                .timestamp = block.timestamp,
                .prev_hash = block.prev_hash,
                .hash = block.hash,
                .nonce = block.nonce,
                .data = try allocator.dupe(u8, block.data),
            });
        }
    }

    pub fn json(self: *const Self, writer: *std.Io.Writer) !void {
        var stringify: std.json.Stringify = .{
            .writer = writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try stringify.write(self.blocks.items);
    }
};

test "blockchain starts with genesis block" {
    const allocator = std.testing.allocator;
    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    const first_block = &blockchain.blocks.items[0];

    try std.testing.expect(std.meta.eql(b.GENESIS, first_block.*));
}

test "blockchain adds new block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    const data = "some data";
    try blockchain.add(io, allocator, data);

    const last_block = &blockchain.blocks.items[blockchain.blocks.items.len - 1];
    try std.testing.expectEqualSlices(u8, data, last_block.data);
}

test "blockchain is valid if no data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    const data = "some data";
    try blockchain.add(io, allocator, data);

    try std.testing.expect(blockchain.isValid());
}

test "blockchain is not valid if data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");
    try blockchain.add(io, allocator, "Another Data");

    const last_block = &blockchain.blocks.items[blockchain.blocks.items.len - 1];
    const corrupted = try allocator.dupe(u8, "Corrupted");
    allocator.free(last_block.data);
    last_block.data = corrupted;

    try std.testing.expect(!blockchain.isValid());
}

test "blockchain replaces if chain is valid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Blockchain = try .init(allocator);
    defer initial.deinit(allocator);

    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");
    try blockchain.add(io, allocator, "Another Data");

    try initial.replace(allocator, &blockchain);
    try std.testing.expect(initial.blocks.items.len == blockchain.blocks.items.len);
}

test "blockchain not replaces if incoming chain is shorter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Blockchain = try .init(allocator);
    defer initial.deinit(allocator);
    try initial.add(io, allocator, "Some data");
    try initial.add(io, allocator, "Some other data");

    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");

    try std.testing.expectError(error.ChainLengthIsEqualOrLess, initial.replace(allocator, &blockchain));
}

test "blockchain not replaces if incoming chain is same length" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Blockchain = try .init(allocator);
    defer initial.deinit(allocator);
    try initial.add(io, allocator, "Some data");

    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "Some data");

    try std.testing.expectError(error.ChainLengthIsEqualOrLess, initial.replace(allocator, &blockchain));
}

test "blockchain not replaces if incoming chain is invalid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Blockchain = try .init(allocator);
    defer initial.deinit(allocator);
    try initial.add(io, allocator, "Some data");

    var blockchain: Blockchain = try .init(allocator);
    defer blockchain.deinit(allocator);
    try blockchain.add(io, allocator, "Some data");
    try blockchain.add(io, allocator, "Some other data");

    const last_block = &blockchain.blocks.items[blockchain.blocks.items.len - 1];
    const corrupted = try allocator.dupe(u8, "Corrupted");
    allocator.free(last_block.data);
    last_block.data = corrupted;

    try std.testing.expectError(error.InvalidChain, initial.replace(allocator, &blockchain));
}

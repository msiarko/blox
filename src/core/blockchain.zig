const b = @import("block.zig");
const Block = b.Block;
const std = @import("std");

const Blocks = std.ArrayList(Block);

pub const Blockchain = struct {
    blocks: Blocks,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var blocks: Blocks = .empty;
        try blocks.append(allocator, b.GENESIS);

        return .{
            .blocks = blocks,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.deinit(allocator);
        }
        self.blocks.deinit(allocator);
    }

    pub fn add(self: *@This(), io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
        if (self.blocks.items.len == 0) return error.BlockchainEmpty;
        const prev_block = &self.blocks.items[self.blocks.items.len - 1];
        const new_block: Block = try .init(io, allocator, &prev_block.hash, data);
        try self.blocks.append(allocator, new_block);
    }

    fn isValid(self: *const @This()) bool {
        if (self.blocks.items.len == 0) return false;

        const genesis = &self.blocks.items[0];

        if (!std.meta.eql(genesis.*, b.GENESIS)) return false;

        for (1..self.blocks.items.len) |i| {
            const curr = &self.blocks.items[i];
            const prev = &self.blocks.items[i - 1];
            if (!std.mem.eql(u8, &curr.prev_hash, &prev.hash) or !curr.isHashValid()) return false;
        }

        return true;
    }

    pub fn replace(self: *@This(), allocator: std.mem.Allocator, chain: *const @This()) !void {
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

    pub fn json(self: *const @This(), writer: *std.Io.Writer) !void {
        var stringify: std.json.Stringify = .{
            .writer = writer,
            .options = .{
                .whitespace = .indent_2,
            },
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

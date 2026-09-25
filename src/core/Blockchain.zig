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

pub fn isValid(self: *const Self, allocator: Allocator) !bool {
    if (self.blocks.len == 0) return false;
    
    const options = @import("options");
    var balances = std.AutoHashMap([33]u8, u64).init(allocator);
    defer balances.deinit();

    for (1..self.blocks.len) |i| {
        const curr = self.blocks.get(i);
        const prev_hash = self.blocks.items(.hash)[i - 1];
        if (!std.mem.eql(u8, &curr.prev_hash, &prev_hash) or !curr.isHashValid())
            return false;
            
        if (curr.data.len > 0) {
            var parsed = std.json.parseFromSlice(
                []const @import("Transaction.zig").Json,
                allocator,
                curr.data,
                .{ .allocate = .alloc_always },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            defer parsed.deinit();
            
            for (parsed.value) |tx_json| {
                var tx = tx_json.toTransaction(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return false,
                };
                defer tx.deinit(allocator);
                
                if (!try tx.verify(allocator)) return false;
                
                const addr = tx.input.address.toCompressedSec1();
                const bal = balances.get(addr) orelse options.initial_balance;
                if (tx.input.amount > bal) return false;
                
                var out_sum: u64 = 0;
                for (tx.outputs.items) |o| out_sum += o.amount;
                if (out_sum != tx.input.amount) return false;
                
                try balances.put(addr, bal - tx.input.amount);
                for (tx.outputs.items) |o| {
                    const o_addr = o.address.toCompressedSec1();
                    const ob = balances.get(o_addr) orelse options.initial_balance;
                    try balances.put(o_addr, ob + o.amount);
                }
            }
        }
    }

    return true;
}

pub fn fromSlice(allocator: Allocator, slice: []const Block) !Self {
    if (slice.len == 0) return error.EmptySlice;
    var blocks: std.MultiArrayList(Block) = try .initCapacity(allocator, slice.len);
    errdefer {
        for (0..blocks.len) |i| {
            var b = blocks.get(i);
            b.deinit(allocator);
        }
        blocks.deinit(allocator);
    }
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
    if (!try chain.isValid(allocator)) return error.InvalidChain;
    for (0..self.blocks.len) |i| {
        const self_block = self.blocks.get(i);
        const chain_block = chain.blocks.get(i);
        if (!self_block.eql(&chain_block))
            return error.InvalidChain;
    }

    for (self.blocks.len..chain.blocks.len) |i| {
        const b = chain.blocks.get(i);
        const data = try allocator.dupe(u8, b.data);
        errdefer allocator.free(data);
        try self.blocks.append(allocator, .{
            .timestamp = b.timestamp,
            .prev_hash = b.prev_hash,
            .hash = b.hash,
            .nonce = b.nonce,
            .difficulty = b.difficulty,
            .data = data,
        });
    }
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

    try blockchain.add(io, allocator, "[]");

    const last_block = try blockchain.getLastBlock();
    try std.testing.expectEqualSlices(u8, "[]", last_block.data);
}

test "blockchain is valid if no data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "[]");
    try std.testing.expect(try blockchain.isValid(allocator));
}

test "blockchain is not valid if data corrupted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "[]");
    const block = try blockchain.getLastBlock();
    try blockchain.add(io, allocator, "[]");

    @constCast(block.data)[0] = '{'; // Break the JSON or hash

    try std.testing.expect(!try blockchain.isValid(allocator));
}

test "blockchain replaces if chain is valid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.add(io, allocator, "[]");
    try blockchain.add(io, allocator, "[]");

    try initial.replace(allocator, &blockchain);
    try std.testing.expect(initial.blocks.len == blockchain.blocks.len);
}

test "blockchain not replaces if incoming chain is shorter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    try initial.add(io, allocator, "[]");
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.replace(allocator, &initial);
    try initial.add(io, allocator, "[]");

    try std.testing.expectError(error.ShortBlockchain, initial.replace(allocator, &blockchain));
}

test "blockchain not replaces if incoming chain is same length" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var initial: Self = try .init(allocator);
    defer initial.deinit(allocator);

    try initial.add(io, allocator, "[]");
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

    try initial.add(io, allocator, "[]");
    var blockchain: Self = try .init(allocator);
    defer blockchain.deinit(allocator);

    try blockchain.replace(allocator, &initial);
    try blockchain.add(io, allocator, "[]");

    const last_block = try blockchain.getLastBlock();
    @constCast(last_block.data)[0] = '{';

    try std.testing.expectError(error.InvalidChain, initial.replace(allocator, &blockchain));
}

test "fromSlice frees memory on OOM" {
    const allocator = std.testing.allocator;
    var genesis_block = try Block.genesis(allocator);
    defer genesis_block.deinit(allocator);

    const data1 = "[]";
    var block1 = try Block.init(std.testing.io, allocator, &genesis_block, data1);
    defer block1.deinit(allocator);

    const data2 = "[]";
    var block2 = try Block.init(std.testing.io, allocator, &block1, data2);
    defer block2.deinit(allocator);

    const blocks_slice = &[_]Block{ genesis_block, block1, block2 };

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 3 });
    const failing_alloc = failing.allocator();

    _ = fromSlice(failing_alloc, blocks_slice) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    return error.TestExpectedOomFailure;
}

test "replace frees memomy on OOM during append" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var initial = try init(allocator);
    defer initial.deinit(allocator);
    initial.blocks.shrinkAndFree(allocator, 1);

    var blockchain = try init(allocator);
    defer blockchain.deinit(allocator);
    
    try blockchain.add(io, allocator, "[]");

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    const failing_alloc = failing.allocator();

    _ = initial.replace(failing_alloc, &blockchain) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    return error.TestExpectedOomFailure;
}

const Block = @import("block.zig");
const std = @import("std");

const Blocks = std.ArrayList(Block);

blocks: Blocks,

pub fn init(allocator: std.mem.Allocator) !@This() {
    var blocks: Blocks = .empty;
    try blocks.append(allocator, Block.GENESIS);

    return .{
        .blocks = blocks,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    for (self.blocks.items) |*block| {
        block.deinit(gpa);
    }
    self.blocks.deinit(gpa);
}

pub fn add(self: *@This(), io: std.Io, gpa: std.mem.Allocator, data: []const u8) !void {
    const prev_block = self.blocks.getLastOrNull() orelse return error.BlockchainEmpty;
    const new_block: Block = try .init(io, gpa, prev_block, data);
    try self.blocks.append(gpa, new_block);
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

test {
    _ = std.testing.refAllDecls(Block);
}

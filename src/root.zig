const std = @import("std");
const Io = std.Io;

pub const core = @import("core");

pub const Application = struct {
    chain: core.Blockchain,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .chain = try .init(allocator),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.chain.deinit(allocator);
    }

    pub fn run(self: *@This(), io: Io, allocator: std.mem.Allocator) !void {
        try self.chain.add(io, allocator, "Some data");
        try self.chain.add(io, allocator, "Some another data");
        try self.chain.add(io, allocator, "Some another important data");

        var buffer: [512]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);

        try self.chain.json(&stdout.interface);
        try stdout.flush();
    }
};

const std = @import("std");
const Io = std.Io;

const blox = @import("blox");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var chain: blox.core.Blockchain = try .init(arena);

    try chain.add(init.io, arena, "Some data");
    try chain.add(init.io, arena, "Some another data");
    try chain.add(init.io, arena, "Some another important data");

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    try chain.json(&stdout.interface);
    try stdout.flush();
}

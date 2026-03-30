const std = @import("std");
const Io = std.Io;

const blox = @import("blox");
const Application = blox.Application;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var app: Application = try .init(arena);
    try app.run(init.io, arena);
}

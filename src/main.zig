const std = @import("std");

const blox = @import("blox");

pub fn main(init: std.process.Init) !void {
    try blox.run(init.io, init.gpa, init.environ_map);
}

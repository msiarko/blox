const std = @import("std");
const blox = @import("blox");

pub fn main(init: std.process.Init) !void {
    var app_state: blox.AppState = try .init(init.gpa);
    defer app_state.deinit(init.gpa);

    try blox.run(init.io, init.gpa, &app_state);
}

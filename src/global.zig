const std = @import("std");
const builtin = @import("builtin");

pub const json_options: std.json.Stringify.Options = .{
    .whitespace = if (builtin.mode == .Debug) .indent_2 else .minified,
};

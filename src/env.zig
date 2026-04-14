const std = @import("std");
const Map = std.process.Environ.Map;
const Dir = std.Io.Dir;

pub fn setupEnv(io: std.Io, allocator: std.mem.Allocator, env: *Map) !void {
    var buffer: [1024]u8 = undefined;
    const content = Dir.cwd().readFile(io, ".env", &buffer) catch |err| {
        std.log.warn("Failed to read .env file: {}\n", .{err});
        return;
    };

    var split = std.mem.splitScalar(u8, content, '\n');
    while (split.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        const line_trimmed = std.mem.trim(u8, line, " \r\n");
        if (line_trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line_trimmed, '=');

        const raw_key = parts.next() orelse continue;
        const key = std.mem.trim(u8, raw_key, " \t");
        if (key.len == 0) continue;

        const raw_value = parts.next() orelse "";
        const value = std.mem.trim(u8, raw_value, " \t");

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);

        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);

        try env.put(owned_key, owned_value);
    }
}

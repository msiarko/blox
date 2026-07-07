const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_length = Sha256.digest_length;
pub const Hash = [digest_length]u8;

pub fn hash(data: anytype) Hash {
    const ti = @typeInfo(@TypeOf(data));
    if (!ti.@"struct".is_tuple)
        @compileError("Expected a tuple");

    var hasher: Sha256 = .init(.{});
    inline for (data) |s| {
        hasher.update(s);
    }

    return hasher.finalResult();
}

fn repeatPattern(comptime T: type, comptime pattern: []const T, comptime n: usize) [pattern.len * n]u8 {
    var buf: [pattern.len * n]u8 = undefined;
    for (0..n) |i| {
        @memcpy(buf[i * pattern.len .. (i + 1) * pattern.len], pattern);
    }
    return buf;
}

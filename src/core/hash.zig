const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_length = Sha256.digest_length;
pub const Hash = [digest_length]u8;

pub fn hash(data: []const u8) Hash {
    var hasher: Sha256 = .init(.{});
    hasher.update(data);
    return hasher.finalResult();
}

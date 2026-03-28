const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const DIGEST_SIZE: usize = Sha256.digest_length;
const ZERO_HASH = [_]u8{0} ** DIGEST_SIZE;
const GENESIS_DATA = "";
const GENESIS_TIMESTAMP: i64 = 0;
const GENESIS_HASH = hashData(GENESIS_TIMESTAMP, ZERO_HASH, GENESIS_DATA);

const Hash = [DIGEST_SIZE]u8;

pub const GENESIS: @This() = .{
    .timestamp = GENESIS_TIMESTAMP,
    .prev_hash = ZERO_HASH,
    .hash = GENESIS_HASH,
    .data = GENESIS_DATA,
};

prev_hash: [32]u8,
hash: [32]u8,
timestamp: i64,
data: []const u8,

fn hashData(timestamp: i64, prev_hash: Hash, data: []const u8) Hash {
    @setEvalBranchQuota(4000);
    var hasher: Sha256 = .init(.{});
    hasher.update(std.mem.asBytes(&timestamp));
    hasher.update(&prev_hash);
    hasher.update(data);

    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

fn initInternal(gpa: std.mem.Allocator, timestamp: i64, prev_hash: Hash, data: []const u8) !@This() {
    const hash = hashData(timestamp, prev_hash, data);
    const data_owned = try gpa.dupe(u8, data);
    return .{
        .timestamp = timestamp,
        .prev_hash = prev_hash,
        .hash = hash,
        .data = data_owned,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    gpa.free(self.data);
}

pub fn init(io: Io, gpa: std.mem.Allocator, prev_block: @This(), data: []const u8) !@This() {
    if (data.len == 0) return error.EmptyData;
    const timestamp = Io.Timestamp.now(io, .real);
    const prev_hash = prev_block.hash;
    return .initInternal(gpa, timestamp.toMilliseconds(), prev_hash, data);
}

pub fn jsonStringify(self: *const @This(), stringify: *std.json.Stringify) !void {
    try stringify.beginObject();

    try stringify.objectField("timestamp");
    try stringify.write(self.timestamp);

    try stringify.objectField("prev_hash");
    try stringify.write(std.fmt.bytesToHex(self.prev_hash, .lower)[0..]);

    try stringify.objectField("hash");
    try stringify.write(std.fmt.bytesToHex(self.hash, .lower)[0..]);

    try stringify.objectField("data");
    try stringify.write(self.data);

    try stringify.endObject();
}

test "first mined block prev hash matches genesis hash" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const data = "Some data";
    var block = try init(io, gpa, GENESIS, data);
    defer block.deinit(gpa);
    try std.testing.expectEqual(GENESIS.hash, block.prev_hash);
}

test "init block data matches input" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const data = "some data";
    var block = try init(io, gpa, GENESIS, data);
    defer block.deinit(gpa);
    try std.testing.expectEqualSlices(u8, data, block.data);
}

test "init block with empty data fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const data = "";
    const block = init(io, gpa, GENESIS, data);
    try std.testing.expectError(error.EmptyData, block);
}

const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const DIGEST_SIZE: usize = Sha256.digest_length;

const options = @import("options");

pub const Hash = [DIGEST_SIZE]u8;
const Timestamp = i64;
const Nonce = u64;

const ZERO_HASH: Hash = [_]u8{0} ** DIGEST_SIZE;
const GENESIS_HASH = hashData(
    options.GENESIS_TIMESTAMP,
    &ZERO_HASH,
    options.GENESIS_NONCE,
    options.GENESIS_DATA,
);

pub const GENESIS: Self = .{
    .timestamp = options.GENESIS_TIMESTAMP,
    .prev_hash = ZERO_HASH,
    .hash = GENESIS_HASH,
    .nonce = options.GENESIS_NONCE,
    .data = options.GENESIS_DATA,
};

const Self = @This();

prev_hash: Hash,
hash: Hash,
timestamp: Timestamp,
nonce: Nonce,
data: []const u8,

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    // Guard: the genesis block's `data` points at a comptime string literal, not a
    // heap allocation. Calling `allocator.free` on it would be undefined behaviour,
    // so we bail out early whenever this block is the genesis block.
    if (std.meta.eql(self.hash, GENESIS_HASH)) return;
    allocator.free(self.data);
}

pub fn init(io: Io, allocator: std.mem.Allocator, prev_hash: *const Hash, data: []const u8) !@This() {
    if (data.len == 0) return error.EmptyData;
    const result = generateHash(io, prev_hash, data);
    // Ownership transfer: the caller supplies a (possibly stack/temporary) slice;
    // we dup it into a fresh heap allocation so that this `Block` owns its `data`
    // for its entire lifetime. `deinit` is responsible for freeing it.
    const data_owned = try allocator.dupe(u8, data);
    return .{
        .timestamp = result.timestamp,
        .prev_hash = prev_hash.*,
        .hash = result.hash,
        .nonce = result.nonce,
        .data = data_owned,
    };
}

pub fn isHashValid(self: *const @This()) bool {
    const generated_hash = hashData(
        self.timestamp,
        &self.prev_hash,
        self.nonce,
        self.data,
    );
    return std.mem.eql(u8, &generated_hash, &self.hash);
}

pub fn jsonStringify(self: *const Self, stringify: anytype) !void {
    try stringify.beginObject();

    try stringify.objectField("timestamp");
    try stringify.write(self.timestamp);

    try stringify.objectField("prev_hash");
    try stringify.write(std.fmt.bytesToHex(self.prev_hash, .lower)[0..]);

    try stringify.objectField("hash");
    try stringify.write(std.fmt.bytesToHex(self.hash, .lower)[0..]);

    try stringify.objectField("nonce");
    try stringify.write(self.nonce);

    try stringify.objectField("data");
    try stringify.write(self.data);

    try stringify.endObject();
}

pub fn eql(self: *const @This(), other: *const @This()) bool {
    return self.timestamp == other.timestamp and
        std.mem.eql(u8, &self.prev_hash, &other.prev_hash) and
        std.mem.eql(u8, &self.hash, &other.hash) and
        self.nonce == other.nonce and
        std.mem.eql(u8, self.data, other.data);
}

const GenerateHashResult = struct {
    hash: Hash,
    nonce: Nonce,
    timestamp: Timestamp,
};

fn generateHash(io: Io, prev_hash: *const Hash, data: []const u8) GenerateHashResult {
    var nonce: Nonce = 0;
    while (true) : (nonce += 1) {
        const timestamp = Io.Timestamp.now(io, .real).toMilliseconds();
        const generated_hash = hashData(
            timestamp,
            prev_hash,
            nonce,
            data,
        );

        if (std.mem.startsWith(u8, &generated_hash, &[_]u8{0} ** options.DIFFICULTY))
            return .{
                .hash = generated_hash,
                .nonce = nonce,
                .timestamp = timestamp,
            };
    }
}

fn hashData(timestamp: Timestamp, prev_hash: *const Hash, nonce: Nonce, data: []const u8) Hash {
    @setEvalBranchQuota(4000);

    var hasher: Sha256 = .init(.{});
    hasher.update(std.mem.asBytes(&timestamp));
    hasher.update(prev_hash);
    hasher.update(data);
    hasher.update(std.mem.asBytes(&nonce));

    return hasher.finalResult();
}

test "first mined block prev hash matches genesis hash" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data = "Some data";
    var block: Self = try .init(io, allocator, &GENESIS.hash, data);
    defer block.deinit(allocator);
    try std.testing.expectEqual(GENESIS.hash, block.prev_hash);
}

test "init block data matches input" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data = "some data";
    var block: Self = try .init(io, allocator, &GENESIS.hash, data);
    defer block.deinit(allocator);
    try std.testing.expectEqualSlices(u8, data, block.data);
}

test "init block with empty data fails" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data = "";
    const block = Self.init(io, allocator, &GENESIS.hash, data);
    try std.testing.expectError(error.EmptyData, block);
}

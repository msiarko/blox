const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const options = @import("options");

pub const Hash = [Sha256.digest_length]u8;
const Timestamp = i64;
const Nonce = u64;

const mine_rate_ms = 3_000;

const Self = @This();

prev_hash: Hash,
hash: Hash,
timestamp: Timestamp,
nonce: Nonce,
data: []const u8,
difficulty: u4,

pub fn genesis(allocator: std.mem.Allocator) !Self {
    const hash = hashData(
        options.genesis_timestamp,
        options.genesis_prev_hash,
        options.genesis_nonce,
        options.genesis_difficulty,
        options.genesis_data,
    );

    return .{
        .timestamp = options.genesis_timestamp,
        .prev_hash = options.genesis_prev_hash,
        .hash = hash,
        .nonce = options.genesis_nonce,
        .difficulty = options.genesis_difficulty,
        .data = try allocator.dupe(u8, options.genesis_data),
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    allocator.free(self.data);
    self.* = undefined;
}

pub fn init(io: Io, allocator: std.mem.Allocator, prev_block: *const Self, data: []const u8) !@This() {
    if (data.len == 0) return error.EmptyData;
    const result = generateHash(io, prev_block, data);
    // Ownership transfer: the caller supplies a (possibly stack/temporary) slice;
    // we dup it into a fresh heap allocation so that this `Block` owns its `data`
    // for its entire lifetime. `deinit` is responsible for freeing it.
    const data_owned = try allocator.dupe(u8, data);
    return .{
        .timestamp = result.timestamp,
        .prev_hash = prev_block.hash,
        .hash = result.hash,
        .nonce = result.nonce,
        .difficulty = result.diffuculty,
        .data = data_owned,
    };
}

pub fn isHashValid(self: *const @This()) bool {
    const generated_hash = hashData(
        self.timestamp,
        self.prev_hash,
        self.nonce,
        self.difficulty,
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

    try stringify.objectField("difficulty");
    try stringify.write(self.difficulty);

    try stringify.objectField("data");
    try stringify.write(self.data);

    try stringify.endObject();
}

pub fn eql(self: *const @This(), other: *const @This()) bool {
    return self.timestamp == other.timestamp and
        std.mem.eql(u8, &self.prev_hash, &other.prev_hash) and
        std.mem.eql(u8, &self.hash, &other.hash) and
        self.nonce == other.nonce and
        self.difficulty == other.difficulty and
        std.mem.eql(u8, self.data, other.data);
}

const GenerateHashResult = struct {
    hash: Hash,
    nonce: Nonce,
    timestamp: Timestamp,
    diffuculty: u4,
};

fn generateHash(io: Io, prev_block: *const Self, data: []const u8) GenerateHashResult {
    var nonce: Nonce = 0;
    var difficulty = prev_block.difficulty;
    while (true) : (nonce += 1) {
        const timestamp = Io.Timestamp.now(io, .real).toMilliseconds();
        difficulty = adjustDifficulty(prev_block, timestamp);
        const generated_hash = hashData(
            timestamp,
            prev_block.hash,
            nonce,
            difficulty,
            data,
        );

        if (std.mem.allEqual(u8, generated_hash[0..difficulty], 0)) {
            return .{
                .hash = generated_hash,
                .nonce = nonce,
                .timestamp = timestamp,
                .diffuculty = difficulty,
            };
        }
    }
}

fn adjustDifficulty(prev_block: *const Self, timestamp: i64) u4 {
    if (prev_block.timestamp + mine_rate_ms > timestamp)
        return prev_block.difficulty + 1;

    return prev_block.difficulty - 1;
}

fn hashData(
    timestamp: Timestamp,
    prev_hash: Hash,
    nonce: Nonce,
    difficulty: u8,
    data: []const u8,
) Hash {
    var hasher: Sha256 = .init(.{});
    hasher.update(std.mem.asBytes(&timestamp));
    hasher.update(&prev_hash);
    hasher.update(data);
    hasher.update(std.mem.asBytes(&nonce));
    hasher.update(std.mem.asBytes(&difficulty));

    return hasher.finalResult();
}

test "first mined block prev hash matches genesis hash" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data = "Some data";
    var genesis_block = try genesis(allocator);
    defer genesis_block.deinit(allocator);

    var block: Self = try .init(io, allocator, &genesis_block, data);
    defer block.deinit(allocator);

    try std.testing.expectEqual(genesis_block.hash, block.prev_hash);
}

test "init block data matches input" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data = "some data";
    var genesis_block = try genesis(allocator);
    defer genesis_block.deinit(allocator);

    var block: Self = try .init(io, allocator, &genesis_block, data);
    defer block.deinit(allocator);

    try std.testing.expectEqualSlices(u8, data, block.data);
}

test "init block with empty data fails" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data = "";
    var genesis_block = try genesis(allocator);
    defer genesis_block.deinit(allocator);

    const block = Self.init(io, allocator, &genesis_block, data);
    try std.testing.expectError(error.EmptyData, block);
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Stringify = std.json.Stringify;

const Blockchain = @import("Blockchain.zig");
const TransactionPool = @import("TransactionPool.zig");
const Wallet = @import("Wallet.zig");
const Block = @import("Block.zig");
const Peer = @import("../Peer.zig");

pub const Ledger = struct {
    const Self = @This();

    chain: Blockchain,
    transaction_pool: TransactionPool,
    wallet: Wallet,
    allocator: Allocator,
    prng: std.Random.DefaultPrng,

    pub fn init(io: Io, allocator: Allocator) !Self {
        const wallet: Wallet = .init(io, null);

        var chain: Blockchain = try .init(allocator);
        errdefer chain.deinit(allocator);

        const genesis_data = "[]";
        try chain.add(io, allocator, genesis_data);

        return .{
            .allocator = allocator,
            .chain = chain,
            .transaction_pool = .init(allocator),
            .wallet = wallet,
            .prng = DefaultPrng.init(@intCast(Io.Timestamp.now(io, .real).toMilliseconds())),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chain.deinit(self.allocator);
        self.transaction_pool.deinit(self.allocator);
    }

    pub fn createTransaction(self: *Self, io: Io, recipient_addr: []const u8, amount: u64) !void {
        var buf: [33]u8 = undefined;
        const sec1 = try std.fmt.hexToBytes(&buf, recipient_addr);
        const pub_key = try Ecdsa.PublicKey.fromSec1(sec1);
        try self.wallet.createTransaction(
            io,
            self.allocator,
            self.prng.random(),
            pub_key,
            amount,
            &self.transaction_pool,
        );
    }

    pub fn mineBlock(self: *Self, io: Io) !void {
        var allocating = Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        var stringify: Stringify = .{ .writer = &allocating.writer, .options = .{} };
        try stringify.write(&self.transaction_pool);

        const data = allocating.written();
        try self.chain.add(io, self.allocator, data);

        self.transaction_pool.transactions.clearRetainingCapacity();
        self.transaction_pool.address_index.clearRetainingCapacity();
    }

    pub fn appendBlock(self: *Self, block: *const Block) !void {
        const last = try self.chain.getLastBlock();
        if (!std.mem.eql(u8, &block.prev_hash, &last.hash)) return error.InvalidChain;

        if (!block.isHashValid()) return error.InvalidChain;

        const data = try self.allocator.dupe(u8, block.data);
        errdefer self.allocator.free(data);

        try self.chain.blocks.append(self.allocator, .{
            .timestamp = block.timestamp,
            .prev_hash = block.prev_hash,
            .hash = block.hash,
            .nonce = block.nonce,
            .difficulty = block.difficulty,
            .data = data,
        });

        if (!try self.chain.isValid(self.allocator)) {
            const popped = self.chain.blocks.pop().?;
            self.allocator.free(popped.data);
            return error.InvalidChain;
        }
    }

    pub fn replaceChain(self: *Self, chain: *const Blockchain) !void {
        return self.chain.replace(self.allocator, chain);
    }
};

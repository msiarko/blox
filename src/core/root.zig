pub const Blockchain = @import("Blockchain.zig");
pub const Wallet = @import("Wallet.zig");
pub const Transaction = @import("Transaction.zig");
pub const TransactionPool = @import("TransactionPool.zig");
pub const uuid = @import("uuid.zig");

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    _ = refAllDecls(Blockchain);
    _ = refAllDecls(Blockchain.Block);
    _ = refAllDecls(Wallet);
    _ = refAllDecls(Transaction);
    _ = refAllDecls(TransactionPool);
}

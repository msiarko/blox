pub const Blockchain = @import("Blockchain.zig");
pub const Wallet = @import("Wallet.zig");
pub const Transaction = @import("Transaction.zig");

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    _ = refAllDecls(Blockchain);
    _ = refAllDecls(Blockchain.Block);
    _ = refAllDecls(Wallet);
    _ = refAllDecls(Transaction);
}

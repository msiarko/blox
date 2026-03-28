const std = @import("std");

pub const Blockchain = @import("blockchain.zig");

test {
    _ = std.testing.refAllDecls(Blockchain);
}

const std = @import("std");
const Io = std.Io;
const Random = std.Random;

pub const Guid = [36]u8;

pub fn genV4(rand: Random) Guid {
    var bytes: [16]u8 = undefined;
    rand.bytes(&bytes);

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var buf: Guid = undefined;
    _ = std.fmt.bufPrint(&buf, "{s}-{s}-{s}-{s}-{s}", .{
        std.fmt.bytesToHex(bytes[0..4], .lower),
        std.fmt.bytesToHex(bytes[4..6], .lower),
        std.fmt.bytesToHex(bytes[6..8], .lower),
        std.fmt.bytesToHex(bytes[8..10], .lower),
        std.fmt.bytesToHex(bytes[10..16], .lower),
    }) catch unreachable;

    return buf;
}

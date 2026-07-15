const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Self = @This();

uri: std.Uri,
uri_buf: ?[]const u8,
message_queue: Io.Queue([]const u8),
buffer: [][]const u8,

pub fn init(allocator: Allocator, peer_uri: []const u8) !Self {
    const buffer = try allocator.alloc([]const u8, 1);
    return .{
        .uri = try std.Uri.parse(peer_uri),
        .buffer = buffer,
        .message_queue = .init(buffer),
        .uri_buf = null,
    };
}

pub fn deinit(self: *Self, io: Io, allocator: Allocator) void {
    self.message_queue.close(io);
    allocator.free(self.buffer);
    if (self.uri_buf) |b| allocator.free(b);
    self.* = undefined;
}

pub fn getHost(self: *const Self) ![]const u8 {
    if (self.uri.host) |host| {
        return switch (host) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };
    }
    return error.UriHostMissing;
}

pub fn getPort(self: *const Self) u16 {
    return self.uri.port orelse 80;
}

pub fn getAddress(self: *const Self) !Io.net.IpAddress {
    const host = try self.getHost();
    const port = self.getPort();
    return try Io.net.IpAddress.parse(host, port);
}

pub fn print(self: *const Self, buffer: []u8) ![]u8 {
    const host = try self.getHost();
    const port = self.getPort();
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ host, port });
}

pub fn parse(allocator: Allocator, peer_uri: []const u8) !Self {
    return .init(allocator, peer_uri);
}

pub fn initFromAddress(allocator: Allocator, address: Io.net.IpAddress) !Self {
    const ip = address.ip4.bytes;
    const uri_string = try std.fmt.allocPrint(
        allocator,
        "ws://{d}.{d}.{d}.{d}:{d}",
        .{ ip[0], ip[1], ip[2], ip[3], address.getPort() },
    );
    errdefer allocator.free(uri_string);
    const buffer = try allocator.alloc([]const u8, 1);
    return .{
        .uri = try std.Uri.parse(uri_string),
        .buffer = buffer,
        .message_queue = .init(buffer),
        .uri_buf = uri_string,
    };
}

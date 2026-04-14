const std = @import("std");
const Io = std.Io;

pub const Peer = struct {
    const Self = @This();

    uri_string: []const u8,
    uri: std.Uri,
    message_queue: Io.Queue([]const u8),
    buffer: [][]const u8,

    pub fn init(allocator: std.mem.Allocator, uri_string: []const u8, uri: std.Uri) !Self {
        const buffer = try allocator.alloc([]const u8, 1);
        return .{
            .uri_string = uri_string,
            .uri = uri,
            .buffer = buffer,
            .message_queue = .init(buffer),
        };
    }

    pub fn deinit(self: *Self, io: Io, allocator: std.mem.Allocator) void {
        self.message_queue.close(io);
        allocator.free(self.buffer);
        allocator.free(self.uri_string);
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
};

pub fn parse(allocator: std.mem.Allocator, peer_str: []const u8) !Peer {
    const uri_string = try allocator.dupe(u8, peer_str);
    errdefer allocator.free(uri_string);
    const uri = try std.Uri.parse(uri_string);
    return Peer.init(allocator, uri_string, uri);
}

pub fn initFromAddress(allocator: std.mem.Allocator, address: Io.net.IpAddress) !Peer {
    const ip = address.ip4.bytes;
    const uri_string = try std.fmt.allocPrint(
        allocator,
        "ws://{d}.{d}.{d}.{d}:{d}",
        .{ ip[0], ip[1], ip[2], ip[3], address.getPort() },
    );
    errdefer allocator.free(uri_string);
    const uri = try std.Uri.parse(uri_string);
    return Peer.init(allocator, uri_string, uri);
}

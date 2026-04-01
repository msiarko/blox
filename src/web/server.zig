const std = @import("std");
const HttpRequest = std.http.Server.Request;
const WebSocket = std.http.Server.WebSocket;
const HttpStatus = std.http.Status;

pub fn Context(comptime State: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        state: *State,
    };
}

pub const Request = struct {
    allocator: std.mem.Allocator,
    http_req: *HttpRequest,

    pub fn getTarget(self: @This()) []const u8 {
        return self.http_req.head.target;
    }

    pub fn getMethod(self: @This()) std.http.Method {
        return self.http_req.head.method;
    }

    pub fn header(self: @This(), name: []const u8) ?[]const u8 {
        var it = self.http_req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    pub fn body_as_json(self: *const @This(), comptime T: type) !std.json.Parsed(T) {
        if (self.http_req.head.content_length == null) return error.BodyLengthUnknown;
        if (self.http_req.head.content_type) |content_type| {
            if (!std.ascii.eqlIgnoreCase(content_type, "application/json")) return error.UnsupportedContentType;
        }

        if (self.http_req.head.method != .POST and
            self.http_req.head.method != .PUT and
            self.http_req.head.method != .PATCH)
        {
            return error.MethodNotAllowed;
        }

        const transfer_buffer = try self.allocator.alloc(u8, self.http_req.head.content_length.?);
        defer self.allocator.free(transfer_buffer);

        const reader = self.http_req.server.reader.bodyReader(
            transfer_buffer,
            self.http_req.head.transfer_encoding,
            self.http_req.head.content_length,
        );

        const data = try reader.readAlloc(self.allocator, self.http_req.head.content_length.?);
        defer self.allocator.free(data);

        return try std.json.parseFromSlice(T, self.allocator, data, .{});
    }

    pub fn upgradeWebsocket(self: *const @This()) !WebSocket {
        const upg = self.http_req.upgradeRequested();
        switch (upg) {
            .websocket => |key| {
                if (key) |k| {
                    const ws = try self.http_req.respondWebSocket(.{ .key = k });
                    try self.http_req.server.out.flush();
                    return ws;
                }
            },
            else => {},
        }
        return error.NotWebSocketRequest;
    }
};

pub fn Router(comptime State: type) type {
    return struct {
        allocator: std.mem.Allocator,
        routes: std.StringHashMap(RouteEntry),

        pub const Handler = *const fn (ctx: *Context(State), req: Request) anyerror!void;

        const RouteEntry = struct {
            handlers: std.AutoHashMap(std.http.Method, Handler),
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .routes = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.routes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.handlers.deinit();
            }
            self.routes.deinit();
        }

        fn addRoute(self: *Self, method: std.http.Method, path: []const u8, handler: Handler) !void {
            var res = try self.routes.getOrPut(path);
            if (!res.found_existing) {
                res.value_ptr.* = .{
                    .handlers = .init(self.allocator),
                };
            }
            try res.value_ptr.handlers.put(method, handler);
        }

        pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
            try self.addRoute(.GET, path, handler);
        }

        pub fn post(self: *Self, path: []const u8, handler: Handler) !void {
            try self.addRoute(.POST, path, handler);
        }
    };
}

pub fn Server(comptime State: type) type {
    return struct {
        router: Router(State),
        ctx: Context(State),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io, state: *State) Self {
            return .{
                .router = .init(allocator),
                .ctx = .{
                    .io = io,
                    .allocator = allocator,
                    .state = state,
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn listen(self: *Self, port: u16) !void {
            const address = try std.Io.net.IpAddress.parse("0.0.0.0", port);
            var server = try std.Io.net.IpAddress.listen(
                &address,
                self.ctx.io,
                .{
                    .reuse_address = true,
                },
            );
            var tasks: std.ArrayList(std.Io.Future(void)) = .empty;
            defer {
                for (tasks.items) |*entry| {
                    entry.cancel(self.ctx.io);
                }

                tasks.deinit(self.ctx.allocator);
                server.deinit(self.ctx.io);
            }

            std.log.info("Server is listening on 0.0.0.0:{d} ...", .{port});

            while (true) {
                const conn = try server.accept(self.ctx.io);
                const task = self.ctx.io.async(handleConnection, .{
                    self,
                    conn,
                });

                try tasks.append(self.ctx.allocator, task);
            }
        }

        fn handleConnection(
            server: *Self,
            conn: std.Io.net.Stream,
        ) void {
            defer conn.close(server.ctx.io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(server.ctx.io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(server.ctx.io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);

            while (true) {
                var req = http_server.receiveHead() catch |err| {
                    std.log.err("Failed to receive head: {}", .{err});
                    break;
                };

                var arena = std.heap.ArenaAllocator.init(server.ctx.allocator);
                defer arena.deinit();

                const req_allocator = arena.allocator();
                const request: Request = .{
                    .allocator = req_allocator,
                    .http_req = &req,
                };

                handleRequest(&server.ctx, &server.router, request) catch |err| {
                    if (err == error.ConnectionClose) break;
                    std.log.err("Handler failed: {}", .{err});
                    request.http_req.respond("Internal Server Error", .{ .status = .internal_server_error }) catch {};
                };
            }
        }

        fn handleRequest(ctx: *Context(State), router: *const Router(State), req: Request) !void {
            var target = req.getTarget();
            if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
                target = target[0..idx];
            }

            const method = req.getMethod();

            if (router.routes.get(target)) |route_entry| {
                if (route_entry.handlers.get(method)) |handler| {
                    return handler(ctx, req);
                } else {
                    return req.http_req.respond("Method Not Allowed", .{ .status = .method_not_allowed });
                }
            } else {
                var buf: [1024]u8 = undefined;
                var len: usize = 0;

                const s = std.fmt.bufPrint(buf[len..], "Not Found target: '{s}'\nKnown routes:\n", .{target}) catch "";
                len += s.len;
                var it = router.routes.iterator();
                while (it.next()) |entry| {
                    const e = std.fmt.bufPrint(buf[len..], " - '{s}'\n", .{entry.key_ptr.*}) catch "";
                    len += e.len;
                }
                return req.http_req.respond(buf[0..len], .{ .status = .not_found });
            }
        }
    };
}

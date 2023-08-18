const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");

/// A context for handling a request.
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    res: std.http.Server.Response,
    path: []const u8,
    query: ?[]const u8,

    pub fn init(http: *std.http.Server) !Context {
        var arena = std.heap.ArenaAllocator.init(http.allocator);
        errdefer arena.deinit();

        var res = try http.accept(.{
            .allocator = arena.allocator(),
            .header_strategy = .{ .dynamic = 10_000 },
        });
        try res.headers.append("Connection", "close");
        try res.wait();

        const uri = try std.Uri.parseWithoutScheme(res.request.target);

        return .{
            .arena = arena,
            .res = res,

            // TODO: check lifetime, maybe we need to dupe this?
            .path = uri.path,
            .query = uri.query,
        };
    }

    pub fn deinit(self: *Context) void {
        _ = self.res.reset();
        self.res.deinit();
        self.arena.deinit();
    }

    /// Reads the request body as JSON.
    pub fn readJson(self: *Context, comptime T: type) !T {
        var reader = std.json.reader(self.res.allocator, self.res.reader());

        return std.json.parseFromTokenSourceLeaky(
            T,
            self.res.allocator,
            &reader,
            .{},
        );
    }

    /// Sends a chunk of data. Automatically sets the transfer encoding to
    /// chunked if it hasn't been set yet.
    pub fn sendChunk(self: *Context, chunk: []const u8) !void {
        if (self.res.state == .waited) {
            self.res.transfer_encoding = .chunked;
            try self.res.do();
        }

        // Response.write() will always write all of the data when the transfer
        // encoding is chunked
        _ = try self.res.write(chunk);
    }

    /// Sends a chunk of JSON. The chunk always ends with a newline.
    pub fn sendJson(self: *Context, body: anytype) !void {
        if (self.res.state == .waited) {
            try self.res.headers.append("Content-Type", "application/json");
        }

        var list = std.ArrayList(u8).init(self.res.allocator);
        defer list.deinit();

        try std.json.stringifyArbitraryDepth(self.res.allocator, body, .{}, list.writer());
        try list.appendSlice("\r\n");
        try self.sendChunk(list.items);
    }

    /// Sends a static resource. The resource is embedded in release builds.
    pub fn sendResource(self: *Context, comptime path: []const u8) !void {
        try self.res.headers.append("Content-Type", comptime mime(std.fs.path.extension(path)) ++ "; charset=utf-8");

        try self.sendChunk(if (comptime builtin.mode != .Debug) @embedFile("../" ++ path) else blk: {
            var f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            break :blk try f.readToEndAlloc(self.res.allocator, std.math.maxInt(usize));
        });
    }
};

/// An instance of our HTTP server.
pub const Server = struct {
    http: std.http.Server,
    thread: std.Thread,

    pub fn start(allocator: std.mem.Allocator, hostname: []const u8, port: u16) !*Server {
        var self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        var http = std.http.Server.init(allocator, .{ .reuse_address = true });
        errdefer http.deinit();

        const address = try std.net.Address.parseIp(hostname, port);
        try http.listen(address);

        self.* = .{
            .http = http,
            .thread = try std.Thread.spawn(.{}, run, .{self}),
        };

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.http.deinit();
        self.http.allocator.destroy(self);
    }

    fn run(self: *Server) !void {
        while (true) {
            var ctx = try Context.init(&self.http);
            defer ctx.deinit();

            defer {
                if (ctx.res.state == .waited) ctx.res.do() catch {};
                ctx.res.finish() catch {};
                std.log.debug("{s} {s} {}", .{ @tagName(ctx.res.request.method), ctx.path, @intFromEnum(ctx.res.status) });
            }

            handleRequest(&ctx) catch |e| {
                if (e == error.OutOfMemory) return e;

                std.log.debug("handleRequest: {}", .{e});
                ctx.res.status = .internal_server_error;
            };
        }
    }

    fn handleRequest(ctx: *Context) !void {
        if (std.mem.startsWith(u8, ctx.path, "/api/")) {
            return api.handler(ctx);
        }

        if (std.mem.endsWith(u8, ctx.path, ".map")) {
            return ctx.sendChunk("{}");
        }

        if (std.mem.eql(u8, ctx.path, "/favicon.ico")) {
            return ctx.sendResource("src/app/favicon.ico");
        }

        if (std.mem.eql(u8, ctx.path, "/app.js")) {
            return ctx.sendResource("zig-out/js/main.js");
        }

        if (std.mem.eql(u8, ctx.path, "/bootstrap.min.css")) {
            return ctx.sendResource("node_modules/bootstrap/dist/css/bootstrap.min.css");
        }

        try ctx.sendResource("src/app/index.html");
    }
};

fn mime(comptime ext: []const u8) []const u8 {
    const mime_types = std.ComptimeStringMap([]const u8, .{
        .{ ".html", "text/html" },
        .{ ".css", "text/css" },
        .{ ".js", "text/javascript" },
    });

    return mime_types.get(ext) orelse "application/octet-stream";
}

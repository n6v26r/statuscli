const std = @import("std");

pub const base_url = "https://status.cafe";

const Cookie = struct {
    name: []u8,
    value: []u8,
};

pub const Response = struct {
    status: std.http.Status,
    location: ?[]u8,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        if (self.location) |v| self.allocator.free(v);
        self.allocator.free(self.body);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,
    cookies: std.array_list.Managed(Cookie),

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .http = .{
                .allocator = allocator,
                .io = std.Io.Threaded.global_single_threaded.io(),
            },
            .cookies = .init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        for (self.cookies.items) |cookie| {
            self.allocator.free(cookie.name);
            self.allocator.free(cookie.value);
        }
        self.cookies.deinit();
        self.http.deinit();
    }

    pub fn get(self: *Client, path: []const u8) !Response {
        return self.request(.GET, path, null, null);
    }

    pub fn postForm(self: *Client, path: []const u8, body: []const u8, referer: []const u8) !Response {
        return self.request(.POST, path, body, referer);
    }

    pub fn hasCookies(self: *const Client) bool {
        return self.cookies.items.len > 0;
    }

    pub fn clearCookies(self: *Client) void {
        for (self.cookies.items) |cookie| {
            self.allocator.free(cookie.name);
            self.allocator.free(cookie.value);
        }
        self.cookies.clearRetainingCapacity();
    }

    pub fn importCookieHeader(self: *Client, header: []const u8) !void {
        self.clearCookies();
        var it = std.mem.splitScalar(u8, header, ';');
        while (it.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t\r\n");
            if (part.len > 0) try self.saveCookie(part);
        }
    }

    fn request(self: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8, referer: ?[]const u8) !Response {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base_url, path });
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        var headers = std.array_list.Managed(std.http.Header).init(self.allocator);
        defer headers.deinit();

        const cookie_header = try self.cookieHeader();
        defer if (cookie_header.len > 0) self.allocator.free(cookie_header);

        if (cookie_header.len > 0) try headers.append(.{ .name = "Cookie", .value = cookie_header });
        try headers.append(.{ .name = "Origin", .value = base_url });
        if (referer) |r| {
            const ref = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base_url, r });
            defer self.allocator.free(ref);
            try headers.append(.{ .name = "Referer", .value = ref });
            return self.send(method, uri, payload, headers.items);
        }
        return self.send(method, uri, payload, headers.items);
    }

    fn send(self: *Client, method: std.http.Method, uri: std.Uri, payload: ?[]const u8, extra_headers: []const std.http.Header) !Response {
        var req = try self.http.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .user_agent = .{ .override = "meooow" },
                .accept_encoding = .omit,
                .content_type = if (payload == null) .default else .{ .override = "application/x-www-form-urlencoded" },
            },
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        if (payload) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
            var writer = try req.sendBodyUnflushed(&.{});
            try writer.writer.writeAll(body);
            try writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var location: ?[]u8 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
                try self.saveCookie(header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "location")) {
                location = try self.allocator.dupe(u8, header.value);
            }
        }

        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();
        _ = try reader.streamRemaining(&body.writer);

        return .{
            .status = response.head.status,
            .location = location,
            .body = try body.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    pub fn cookieHeader(self: *Client) ![]u8 {
        if (self.cookies.items.len == 0) return "";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        for (self.cookies.items, 0..) |cookie, i| {
            if (i > 0) try out.writer.writeAll("; ");
            try out.writer.print("{s}={s}", .{ cookie.name, cookie.value });
        }
        return out.toOwnedSlice();
    }

    fn saveCookie(self: *Client, header: []const u8) !void {
        const pair = std.mem.sliceTo(header, ';');
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (name.len == 0) return;

        for (self.cookies.items) |*cookie| {
            if (std.mem.eql(u8, cookie.name, name)) {
                self.allocator.free(cookie.value);
                cookie.value = try self.allocator.dupe(u8, value);
                return;
            }
        }

        try self.cookies.append(.{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }
};

const std = @import("std");
const rest = @import("rest.zig");
const utils = @import("utils.zig");
const loginForm = @import("tui.zig").loginForm;
const readLine = @import("tui.zig").readLine;

const session_dir = ".local/share/statscli";
const session_file = session_dir ++ "/session";
const status_template = @embedFile("example.txt");

pub const Client = struct {
    allocator: std.mem.Allocator,
    home: []const u8,
    rest: rest.Client,
    username: []u8 = "",

    pub fn init(allocator: std.mem.Allocator, home: []const u8) Client {
        return .{
            .allocator = allocator,
            .home = home,
            .rest = rest.Client.init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.username.len > 0) self.allocator.free(self.username);
        self.rest.deinit();
    }

    pub fn login(self: *Client, name: []const u8, password: []const u8) !void {
        var login_page = try self.rest.get("/login");
        defer login_page.deinit();
        const csrf = try utils.csrfToken(self.allocator, login_page.body);
        defer self.allocator.free(csrf);

        const form = try utils.encodeForm(self.allocator, &.{
            .{ .name = utils.csrf_name, .value = csrf },
            .{ .name = "name", .value = name },
            .{ .name = "password", .value = password },
        });
        defer self.allocator.free(form);

        var resp = try self.rest.postForm("/check-login", form, "/login");
        defer resp.deinit();

        if (resp.status.class() == .redirect and resp.location != null) {
            const location = resp.location.?;
            var home = try self.rest.get(if (std.mem.startsWith(u8, location, rest.base_url)) location[rest.base_url.len..] else location);
            defer home.deinit();
            if (!utils.containsUserLink(home.body, name)) return error.LoginFailed;
        } else if (!utils.containsUserLink(resp.body, name)) {
            return error.LoginFailed;
        }

        if (self.username.len > 0) self.allocator.free(self.username);
        self.username = try self.allocator.dupe(u8, name);
    }

    pub fn loadSession(self: *Client, io: std.Io) !bool {
        var home_dir = try self.openHomeDir(io);
        defer home_dir.close(io);

        const data = home_dir.readFileAlloc(io, session_file, self.allocator, .limited(8192)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        defer self.allocator.free(data);
        const header = std.mem.trim(u8, data, " \t\r\n");
        if (header.len == 0) return false;
        try self.rest.importCookieHeader(header);
        return self.rest.hasCookies();
    }

    pub fn saveSession(self: *Client, io: std.Io) !void {
        if (!self.rest.hasCookies()) return error.NotLoggedIn;
        var home_dir = try self.openHomeDir(io);
        defer home_dir.close(io);

        try home_dir.createDirPath(io, session_dir);

        const header = try self.rest.cookieHeader();
        defer if (header.len > 0) self.allocator.free(header);
        try home_dir.writeFile(io, .{ .sub_path = session_file, .data = header });
    }

    pub fn deleteSession(self: *Client, io: std.Io) !void {
        var home_dir = try self.openHomeDir(io);
        defer home_dir.close(io);

        home_dir.deleteFile(io, session_file) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        self.rest.clearCookies();
    }

    pub fn logout(self: *Client) !void {
        var resp = try self.rest.get("/logout");
        defer resp.deinit();
        if (self.username.len > 0) {
            self.allocator.free(self.username);
            self.username = "";
        }
    }

    pub fn postStatus(self: *Client, content: []const u8, face: []const u8) !void {
        var page = try self.rest.get("/add");
        defer page.deinit();
        const csrf = try utils.csrfToken(self.allocator, page.body);
        defer self.allocator.free(csrf);

        const form = try utils.encodeForm(self.allocator, &.{
            .{ .name = utils.csrf_name, .value = csrf },
            .{ .name = "content", .value = content },
            .{ .name = "face", .value = face },
        });
        defer self.allocator.free(form);

        var resp = try self.rest.postForm("/add", form, "/");
        defer resp.deinit();
        // I got 302 when testing
        if (@intFromEnum(resp.status) / 100 > 4) return error.PostFailed;
    }

    fn openHomeDir(self: *Client, io: std.Io) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(io, self.home, .{});
    }
};

fn printMsg(io: std.Io, content: []const u8, face: []const u8) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    stdout.interface.print("Emoji: {s}\nContent: {s}\n\nPress <Enter> to post", .{ face, content }) catch {};
    stdout.interface.flush() catch {};
}

pub fn printUsage(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    defer stdout.interface.flush() catch {};
    try stdout.interface.writeAll(
        \\usage:
        \\  statscli login
        \\  statscli add
        \\  statscli del    [TODO]
        \\  statscli logout
        \\
    );
}

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    home: []const u8,
    cmd: []const u8,
    args: *std.process.Args.Iterator,
) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    defer stdout.interface.flush() catch {};
    var client = Client.init(allocator, home);
    defer client.deinit();

    if (std.mem.eql(u8, cmd, "login")) {
        const name, const password = try loginForm(allocator);
        defer allocator.free(name);
        defer allocator.free(password);
        try client.login(name, password);
        try client.saveSession(io);
        try stdout.interface.print("logged in as {s}\n", .{name});
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        const path = args.next() orelse "/tmp/statscli";
        if (!try client.loadSession(io)) return error.NotLoggedIn;
        try editFile(allocator, io, environ_map, path);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
        defer allocator.free(data);
        const msg = try utils.parseMessage(allocator, data);
        defer msg.deinit(allocator);

        // Wait for enter
        printMsg(io, msg.content, msg.face);
        const line = try readLine(allocator);
        defer allocator.free(line);

        try client.postStatus(msg.content, msg.face);
        if (std.mem.eql(u8, path, "/tmp/statscli")) {
            try deleteFileIfExists(io, path);
        }
        try stdout.interface.writeAll("posted\n");
        return;
    }

    if (std.mem.eql(u8, cmd, "logout")) {
        _ = try client.loadSession(io);
        try client.logout();
        try client.deleteSession(io);
        try stdout.interface.writeAll("logged out\n");
        return;
    }

    return error.UnknownCommand;
}

fn editFile(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, path: []const u8) !void {
    ensureFile(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const editor = environ_map.get("EDITOR") orelse "vi";
    var argv: std.array_list.Managed([]const u8) = .init(allocator);
    defer argv.deinit();

    var parts = std.mem.tokenizeAny(u8, editor, " \t");
    while (parts.next()) |part| try argv.append(part);
    if (argv.items.len == 0) try argv.append("vi");
    try argv.append(path);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.EditorFailed,
        else => return error.EditorFailed,
    }
}

fn ensureFile(io: std.Io, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = path,
                .data = status_template,
                .flags = .{ .exclusive = true },
            });
            return;
        },
        else => |e| return e,
    };
    file.close(io);
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return;
        },
        else => |e| return e,
    };
    file.close(io);
    try std.Io.Dir.cwd().deleteFile(io, path);
}

test {
    std.testing.refAllDecls(@This());
}

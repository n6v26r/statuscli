/// I'm too lazy to use a propper tui lib
const std = @import("std");

pub fn loginForm(allocator: std.mem.Allocator) !struct { []u8, []u8 } {
    std.debug.print("username: ", .{});
    const username = try readLine(allocator);
    errdefer allocator.free(username);

    std.debug.print("password: ", .{});
    const password = try readPassword(allocator);
    errdefer allocator.free(password);

    return .{ username, password };
}

fn readPassword(allocator: std.mem.Allocator) ![]u8 {
    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var no_echo = original;
    no_echo.lflag.ECHO = false;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, no_echo);
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};
    defer std.debug.print("\n", .{});

    return readLine(allocator);
}

pub fn readLine(allocator: std.mem.Allocator) ![]u8 {
    var line: std.array_list.Managed(u8) = .init(allocator);
    errdefer line.deinit();

    var buf: [128]u8 = undefined;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &buf);
        if (n == 0) {
            if (line.items.len == 0) return error.EndOfStream;
            break;
        }

        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |end| {
            try line.appendSlice(buf[0..end]);
            break;
        }

        try line.appendSlice(buf[0..n]);
    }

    if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
        _ = line.pop();
    }

    return line.toOwnedSlice();
}

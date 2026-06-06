const std = @import("std");

pub const csrf_name = "gorilla.csrf.Token";

pub fn csrfToken(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const name_pos = std.mem.indexOf(u8, body, "name=\"gorilla.csrf.Token\"") orelse return error.CsrfNotFound;
    const after_name = body[name_pos..];
    const value_key = "value=\"";
    const value_pos = std.mem.indexOf(u8, after_name, value_key) orelse return error.CsrfNotFound;
    const value_start = value_pos + value_key.len;
    const value_end = std.mem.indexOfScalar(u8, after_name[value_start..], '"') orelse return error.CsrfNotFound;
    return htmlUnescape(allocator, after_name[value_start..][0..value_end]);
}

pub fn containsUserLink(body: []const u8, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (name.len + "/users/".len > buf.len) return false;
    const needle = std.fmt.bufPrint(&buf, "/users/{s}", .{name}) catch return false;
    return std.mem.indexOf(u8, body, needle) != null;
}

pub const FormField = struct {
    name: []const u8,
    value: []const u8,
};

pub const Message = struct {
    face: []u8,
    content: []u8,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.face);
        allocator.free(self.content);
    }
};

pub fn encodeForm(allocator: std.mem.Allocator, fields: []const FormField) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (fields, 0..) |field, i| {
        if (i > 0) try out.writer.writeByte('&');
        try formEscape(&out.writer, field.name);
        try out.writer.writeByte('=');
        try formEscape(&out.writer, field.value);
    }
    return out.toOwnedSlice();
}

fn formEscape(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try writer.writeByte(c);
        } else if (c == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}

pub fn parseMessage(allocator: std.mem.Allocator, data: []const u8) !Message {
    const separator_start = findSeparator(data) orelse return error.SeparatorNotFound;
    const header = data[0..separator_start];
    const body = data[separator_start..];

    const face = try selectedFace(allocator, header);
    errdefer allocator.free(face);

    const final_content = try allocator.dupe(u8, std.mem.trim(u8, body, " \t\r\n"));
    if (final_content.len == 0) {
        allocator.free(final_content);
        return error.EmptyMessage;
    }
    return .{ .face = face, .content = final_content };
}

fn findSeparator(data: []const u8) ?usize {
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw, " \t");
        const line_len = raw.len + @intFromBool(offset + raw.len < data.len);
        offset += line_len;

        if (std.mem.startsWith(u8, line, "---")) return offset;
    }
    return null;
}

fn selectedFace(allocator: std.mem.Allocator, header: []const u8) ![]u8 {
    const open = std.mem.indexOfScalar(u8, header, '[') orelse return error.FaceNotFound;
    const rest = header[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.FaceNotFound;
    const face = std.mem.trim(u8, rest[0..close], " \t\r\n");
    if (face.len == 0) return error.FaceNotFound;
    return allocator.dupe(u8, face);
}

pub fn htmlUnescape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '&') {
            if (i + 3 < value.len and value[i + 1] == '#') {
                const semi_rel = std.mem.indexOfScalar(u8, value[i..], ';') orelse {
                    try out.writer.writeByte(value[i]);
                    i += 1;
                    continue;
                };
                const entity = value[i + 2 .. i + semi_rel];
                const codepoint = if (entity.len > 1 and (entity[0] == 'x' or entity[0] == 'X'))
                    std.fmt.parseInt(u21, entity[1..], 16) catch null
                else
                    std.fmt.parseInt(u21, entity, 10) catch null;
                if (codepoint) |cp| {
                    var buf: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &buf);
                    try out.writer.writeAll(buf[0..n]);
                    i += semi_rel + 1;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, value[i..], "&amp;")) {
                try out.writer.writeByte('&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, value[i..], "&quot;")) {
                try out.writer.writeByte('"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, value[i..], "&#43;")) {
                try out.writer.writeByte('+');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, value[i..], "&lt;")) {
                try out.writer.writeByte('<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, value[i..], "&gt;")) {
                try out.writer.writeByte('>');
                i += 4;
                continue;
            }
        }
        try out.writer.writeByte(value[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

test "csrf token" {
    const token = try csrfToken(std.testing.allocator, "<input type=\"hidden\" name=\"gorilla.csrf.Token\" value=\"abc&#43;123==\">");
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("abc+123==", token);
}

test "encode form" {
    const body = try encodeForm(std.testing.allocator, &.{.{ .name = "a b", .value = "x+y" }});
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("a+b=x%2By", body);
}

test "parse message" {
    const msg = try parseMessage(std.testing.allocator,
        \\🙂😎[✨]🥰😂
        \\------------
        \\
        \\hello
        \\world
        \\
    );
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("✨", msg.face);
    try std.testing.expectEqualStrings("hello\nworld", msg.content);
}

test "parse message empty body" {
    try std.testing.expectError(error.EmptyMessage, parseMessage(std.testing.allocator,
        \\[🙂]
        \\------------
        \\
    ));
}

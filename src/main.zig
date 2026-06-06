const std = @import("std");
const root = @import("root.zig");

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        printError(init.io, err);
        std.process.exit(1);
    };
}

// lazy and hacky but works
fn mainInner(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();

    _ = args.next();
    if (args.next()) |cmd| {
        try root.runCli(init.gpa, init.io, init.environ_map, init.environ_map.get("HOME") orelse ".", cmd, &args);
        return;
    }

    try root.printUsage(init.io);
}

fn printError(io: std.Io, err: anyerror) void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    stderr.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
    stderr.interface.flush() catch {};
}

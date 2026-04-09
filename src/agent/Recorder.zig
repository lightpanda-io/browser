const std = @import("std");
const Command = @import("Command.zig");

const Self = @This();

file: ?std.fs.File,
needs_separator: bool,

pub fn init(path: ?[]const u8) Self {
    const file: ?std.fs.File = if (path) |p|
        std.fs.cwd().createFile(p, .{}) catch |err| blk: {
            std.debug.print("Warning: could not open recording file: {s}\n", .{@errorName(err)});
            break :blk null;
        }
    else
        null;

    return .{ .file = file, .needs_separator = false };
}

pub fn deinit(self: *Self) void {
    if (self.file) |f| f.close();
}

/// Record a successfully executed command to the .panda file.
/// Skips read-only commands based on `Command.isRecorded()`.
pub fn record(self: *Self, cmd: Command.Command) void {
    const f = self.file orelse return;
    if (!cmd.isRecorded()) return;

    var buf: [4096]u8 = undefined;
    var file_writer = f.writerStreaming(&buf);
    const writer = &file_writer.interface;
    writer.print("{f}\n", .{cmd}) catch return;
    writer.flush() catch return;
    self.needs_separator = true;
}

/// Record a comment line (e.g. user's natural language input).
pub fn recordComment(self: *Self, comment: []const u8) void {
    const f = self.file orelse return;
    var buf: [4096]u8 = undefined;
    var file_writer = f.writerStreaming(&buf);
    const writer = &file_writer.interface;
    if (self.needs_separator) writer.writeByte('\n') catch return;
    self.needs_separator = true;
    writer.writeAll("# ") catch return;
    writer.writeAll(comment) catch return;
    writer.writeByte('\n') catch return;
    writer.flush() catch return;
}

// --- Tests ---

test "record writes state-mutating commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test.panda", .{ .read = true }) catch unreachable;

    var recorder = Self{ .file = file, .needs_separator = false };
    defer recorder.deinit();

    recorder.record(Command.parse("GOTO https://example.com"));
    recorder.record(Command.parse("CLICK \"Login\""));
    recorder.record(Command.parse("TREE")); // should be skipped
    recorder.record(Command.parse("WAIT \".dashboard\"")); // should be skipped
    recorder.record(Command.parse("MARKDOWN")); // should be skipped
    recorder.record(Command.parse("EXTRACT \".title\""));
    recorder.recordComment("LOGIN");

    // Read back and verify
    file.seekTo(0) catch unreachable;
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "GOTO https://example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "CLICK 'Login'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "EXTRACT '.title'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\n# LOGIN\n") != null);
    // Verify skipped commands are NOT present
    try std.testing.expect(std.mem.indexOf(u8, content, "TREE") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "WAIT") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "MARKDOWN") == null);
}

test "record skips empty and comment lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test2.panda", .{ .read = true }) catch unreachable;

    var recorder = Self{ .file = file, .needs_separator = false };
    defer recorder.deinit();

    recorder.record(Command.parse(""));
    recorder.record(Command.parse("   "));
    recorder.record(Command.parse("# this is a comment"));
    recorder.record(Command.parse("GOTO https://example.com"));

    file.seekTo(0) catch unreachable;
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expectEqualStrings("GOTO https://example.com\n", content);
}

test "recorder with null file is no-op" {
    var recorder = Self{ .file = null, .needs_separator = false };
    recorder.record(Command.parse("GOTO https://example.com"));
    recorder.recordComment("# test");
    recorder.deinit();
}

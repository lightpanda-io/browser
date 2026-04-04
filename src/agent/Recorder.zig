const std = @import("std");
const Command = @import("Command.zig");

const Self = @This();

file: ?std.fs.File,

/// Commands that are read-only / ephemeral and should NOT be recorded.
pub fn init(path: ?[]const u8) Self {
    const file: ?std.fs.File = if (path) |p|
        std.fs.cwd().createFile(p, .{ .truncate = false }) catch |err| blk: {
            std.debug.print("Warning: could not open recording file: {s}\n", .{@errorName(err)});
            break :blk null;
        }
    else
        null;

    // Seek to end for appending
    if (file) |f| {
        f.seekFromEnd(0) catch {};
    }

    return .{ .file = file };
}

pub fn deinit(self: *Self) void {
    if (self.file) |f| f.close();
}

/// Record a successfully executed command line to the .panda file.
/// Skips read-only commands (WAIT, TREE, MARKDOWN).
pub fn record(self: *Self, line: []const u8) void {
    const f = self.file orelse return;

    // Check if this command should be skipped
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (trimmed[0] == '#') return;

    const cmd_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    const cmd_word = trimmed[0..cmd_end];

    if (isNonRecordedCommand(cmd_word)) return;

    f.writeAll(trimmed) catch return;
    f.writeAll("\n") catch return;
}

/// Record a comment line (e.g. # INTENT: ...).
pub fn recordComment(self: *Self, comment: []const u8) void {
    const f = self.file orelse return;
    f.writeAll(comment) catch return;
    f.writeAll("\n") catch return;
}

fn isNonRecordedCommand(cmd_word: []const u8) bool {
    const non_recorded = [_][]const u8{ "WAIT", "TREE", "MARKDOWN", "MD" };
    inline for (non_recorded) |skip| {
        if (eqlIgnoreCase(cmd_word, skip)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, comptime upper: []const u8) bool {
    if (a.len != upper.len) return false;
    for (a, upper) |ac, uc| {
        if (std.ascii.toUpper(ac) != uc) return false;
    }
    return true;
}

// --- Tests ---

test "isNonRecordedCommand" {
    try std.testing.expect(isNonRecordedCommand("WAIT"));
    try std.testing.expect(isNonRecordedCommand("wait"));
    try std.testing.expect(isNonRecordedCommand("TREE"));
    try std.testing.expect(isNonRecordedCommand("MARKDOWN"));
    try std.testing.expect(isNonRecordedCommand("MD"));
    try std.testing.expect(isNonRecordedCommand("md"));
    try std.testing.expect(!isNonRecordedCommand("GOTO"));
    try std.testing.expect(!isNonRecordedCommand("CLICK"));
    try std.testing.expect(!isNonRecordedCommand("EXTRACT"));
}

test "record writes state-mutating commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test.panda", .{ .read = true }) catch unreachable;

    var recorder = Self{ .file = file };
    defer recorder.deinit();

    recorder.record("GOTO https://example.com");
    recorder.record("CLICK \"Login\"");
    recorder.record("TREE"); // should be skipped
    recorder.record("WAIT \".dashboard\""); // should be skipped
    recorder.record("MARKDOWN"); // should be skipped
    recorder.record("EXTRACT \".title\"");
    recorder.recordComment("# INTENT: LOGIN");

    // Read back and verify
    file.seekTo(0) catch unreachable;
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "GOTO https://example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "CLICK \"Login\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "EXTRACT \".title\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "# INTENT: LOGIN\n") != null);
    // Verify skipped commands are NOT present
    try std.testing.expect(std.mem.indexOf(u8, content, "TREE") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "WAIT") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "MARKDOWN") == null);
}

test "record skips empty and comment lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test2.panda", .{ .read = true }) catch unreachable;

    var recorder = Self{ .file = file };
    defer recorder.deinit();

    recorder.record("");
    recorder.record("   ");
    recorder.record("# this is a comment");
    recorder.record("GOTO https://example.com");

    file.seekTo(0) catch unreachable;
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expectEqualStrings("GOTO https://example.com\n", content);
}

test "recorder with null file is no-op" {
    var recorder = Self{ .file = null };
    recorder.record("GOTO https://example.com");
    recorder.recordComment("# test");
    recorder.deinit();
}

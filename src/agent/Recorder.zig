const std = @import("std");
const lp = @import("lightpanda");
const log = lp.log;
const Command = @import("Command.zig");

const Self = @This();

allocator: std.mem.Allocator,
file: ?std.fs.File,
/// Reused between writes so each line doesn't alloc/free.
buf: std.Io.Writer.Allocating,

/// Append-open `path`, inserting a leading newline if the file is non-empty.
/// A null path disables recording.
pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) Self {
    const file: ?std.fs.File = if (path) |p| blk: {
        const f = std.fs.cwd().createFile(p, .{ .truncate = false }) catch |err| {
            log.warn(.app, "could not open recording file", .{ .err = @errorName(err) });
            break :blk null;
        };
        f.seekFromEnd(0) catch |err| {
            log.warn(.app, "could not seek recording file", .{ .err = @errorName(err) });
            f.close();
            break :blk null;
        };
        const pos = f.getPos() catch 0;
        if (pos > 0) f.writeAll("\n") catch {};
        break :blk f;
    } else null;

    return .{ .allocator = allocator, .file = file, .buf = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.buf.deinit();
    if (self.file) |f| f.close();
}

pub fn record(self: *Self, cmd: Command.Command) void {
    const f = self.file orelse return;
    if (!cmd.isRecorded()) return;

    self.buf.clearRetainingCapacity();
    cmd.format(&self.buf.writer) catch return;
    self.buf.writer.writeByte('\n') catch return;
    f.writeAll(self.buf.written()) catch return;
}

pub fn recordComment(self: *Self, comment: []const u8) void {
    const f = self.file orelse return;
    self.buf.clearRetainingCapacity();
    self.buf.writer.writeAll("# ") catch return;
    self.buf.writer.writeAll(comment) catch return;
    self.buf.writer.writeByte('\n') catch return;
    f.writeAll(self.buf.written()) catch return;
}

test "record writes state-mutating commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test.lp", .{ .read = true }) catch unreachable;

    var recorder: Self = .{ .allocator = std.testing.allocator, .file = file, .buf = .init(std.testing.allocator) };
    defer recorder.deinit();

    recorder.record(Command.parse("GOTO https://example.com"));
    recorder.record(Command.parse("CLICK \"Login\""));
    recorder.record(Command.parse("TREE"));
    recorder.record(Command.parse("WAIT \".dashboard\""));
    recorder.record(Command.parse("MARKDOWN"));
    recorder.record(Command.parse("SCROLL 0 200"));
    recorder.record(Command.parse("HOVER '#menu'"));
    recorder.record(Command.parse("SELECT '#country' 'France'"));
    recorder.record(Command.parse("CHECK '#agree'"));
    recorder.record(Command.parse("CHECK '#newsletter' false"));
    recorder.record(Command.parse("EXTRACT \".title\""));
    recorder.recordComment("LOGIN");

    // Read back and verify
    file.seekTo(0) catch unreachable;
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "GOTO https://example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "CLICK 'Login'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "WAIT '.dashboard'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "SCROLL 0 200\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "HOVER '#menu'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "SELECT '#country' 'France'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "CHECK '#agree'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "CHECK '#newsletter' false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "EXTRACT '.title'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\n# LOGIN\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "TREE") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "MARKDOWN") == null);
}

test "record skips empty and comment lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test2.lp", .{ .read = true }) catch unreachable;

    var recorder: Self = .{ .allocator = std.testing.allocator, .file = file, .buf = .init(std.testing.allocator) };
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
    var recorder: Self = .{ .allocator = std.testing.allocator, .file = null, .buf = .init(std.testing.allocator) };
    recorder.record(Command.parse("GOTO https://example.com"));
    recorder.recordComment("# test");
    recorder.deinit();
}

test "init appends to an existing file without truncating" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed a file with a prior line.
    {
        const seed = tmp.dir.createFile("script.lp", .{}) catch unreachable;
        defer seed.close();
        _ = seed.writeAll("GOTO https://example.com\n") catch unreachable;
    }

    // Resolve absolute path for Recorder.init (which uses std.fs.cwd()).
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp.dir.realpath("script.lp", &path_buf) catch unreachable;

    var recorder: Self = .init(std.testing.allocator, abs_path);
    defer recorder.deinit();
    recorder.record(Command.parse("CLICK 'Login'"));

    // Read back.
    const file = tmp.dir.openFile("script.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "GOTO https://example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "CLICK 'Login'\n") != null);
    // The prior line must precede the appended line.
    const prior = std.mem.indexOf(u8, content, "GOTO").?;
    const appended = std.mem.indexOf(u8, content, "CLICK").?;
    try std.testing.expect(prior < appended);
}

test "init creates the file if missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = tmp.dir.realpath(".", &path_buf) catch unreachable;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fmt.bufPrint(&full_buf, "{s}/fresh.lp", .{dir_path}) catch unreachable;

    var recorder: Self = .init(std.testing.allocator, abs_path);
    defer recorder.deinit();
    recorder.record(Command.parse("GOTO https://example.com"));

    const file = tmp.dir.openFile("fresh.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    try std.testing.expectEqualStrings("GOTO https://example.com\n", buf[0..n]);
}

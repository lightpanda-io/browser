// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");
const log = lp.log;
const Command = @import("Command.zig");

const Self = @This();

allocator: std.mem.Allocator,
file: ?std.fs.File,
/// Path of the active recording, owned by the Recorder. null when disabled.
path: ?[]const u8,
/// Set when the user requested recording but init failed. Lets callers
/// surface the reason in the UI instead of burying it in logs.
init_error: ?[]const u8 = null,
/// Number of lines successfully appended since init. Bumped only on success
/// so callers see the actual file line count, not the attempt count.
lines: u32,
/// Reused between writes so each line doesn't alloc/free.
buf: std.Io.Writer.Allocating,

/// Append-open `path`, inserting a leading newline if the file is non-empty.
/// A null path disables recording. Open failures are captured in `init_error`
/// so callers can surface them in the UI; `init` itself never fails.
pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) Self {
    var self: Self = .{
        .allocator = allocator,
        .file = null,
        .path = null,
        .lines = 0,
        .buf = .init(allocator),
    };
    const p = path orelse return self;
    const owned_path = allocator.dupe(u8, p) catch |err| {
        log.warn(.app, "recording path alloc failed", .{ .err = @errorName(err) });
        self.init_error = @errorName(err);
        return self;
    };
    const f = openForAppend(p) catch |err| {
        log.warn(.app, "recording file open failed", .{ .err = @errorName(err) });
        allocator.free(owned_path);
        self.init_error = @errorName(err);
        return self;
    };
    self.file = f;
    self.path = owned_path;
    return self;
}

fn openForAppend(path: []const u8) !std.fs.File {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    errdefer f.close();
    try f.seekFromEnd(0);
    const pos = try f.getPos();
    if (pos > 0) try f.writeAll("\n");
    return f;
}

pub fn deinit(self: *Self) void {
    self.buf.deinit();
    if (self.file) |f| f.close();
    if (self.path) |p| self.allocator.free(p);
}

pub fn isActive(self: *const Self) bool {
    return self.file != null;
}

pub fn record(self: *Self, cmd: Command.Command) void {
    if (self.file == null) return;
    if (!cmd.isRecorded()) return;

    self.buf.clearRetainingCapacity();
    cmd.format(&self.buf.writer) catch return;
    self.buf.writer.writeByte('\n') catch return;
    self.writeOrDisable(self.buf.written()) catch return;
    self.lines += 1;
}

pub fn recordComment(self: *Self, comment: []const u8) void {
    if (self.file == null) return;
    self.buf.clearRetainingCapacity();
    // Embedded newlines would smuggle an executable line into the script on
    // replay (e.g. `# foo\nGOTO https://attacker`). Emit each line of the
    // comment as its own `# ` line; strip lone CRs.
    var it = std.mem.splitScalar(u8, comment, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        self.buf.writer.writeAll("# ") catch return;
        self.buf.writer.writeAll(trimmed) catch return;
        self.buf.writer.writeByte('\n') catch return;
    }
    self.writeOrDisable(self.buf.written()) catch return;
    self.lines += 1;
}

/// Write the buffered line to the recording file. On failure, close the
/// file and null out `self.file` so `isActive()` flips to false and the
/// caller can surface that the recording stopped — rather than silently
/// dropping subsequent appends.
fn writeOrDisable(self: *Self, bytes: []const u8) !void {
    const f = self.file.?;
    f.writeAll(bytes) catch |err| {
        log.warn(.app, "recording disabled", .{ .err = @errorName(err) });
        f.close();
        self.file = null;
        return err;
    };
}

test "record writes state-mutating commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test.lp", .{ .read = true }) catch unreachable;

    var recorder: Self = .{
        .allocator = std.testing.allocator,
        .file = file,
        .path = null,
        .lines = 0,
        .buf = .init(std.testing.allocator),
    };
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
    recorder.record(Command.parse("EXTRACT '{\"title\":\".title\"}'"));
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
    try std.testing.expect(std.mem.indexOf(u8, content, "EXTRACT '{\"title\":\".title\"}'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\n# LOGIN\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "TREE") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "MARKDOWN") == null);
}

test "record skips empty and comment lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("test2.lp", .{ .read = true }) catch unreachable;

    var recorder: Self = .{
        .allocator = std.testing.allocator,
        .file = file,
        .path = null,
        .lines = 0,
        .buf = .init(std.testing.allocator),
    };
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
    var recorder: Self = .{
        .allocator = std.testing.allocator,
        .file = null,
        .path = null,
        .lines = 0,
        .buf = .init(std.testing.allocator),
    };
    recorder.record(Command.parse("GOTO https://example.com"));
    recorder.recordComment("# test");
    try std.testing.expectEqual(@as(u32, 0), recorder.lines);
    recorder.deinit();
}

test "lines counter tracks successful appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("count.lp", .{ .read = true }) catch unreachable;

    var recorder: Self = .{
        .allocator = std.testing.allocator,
        .file = file,
        .path = null,
        .lines = 0,
        .buf = .init(std.testing.allocator),
    };
    defer recorder.deinit();

    recorder.record(Command.parse("GOTO https://example.com")); // +1
    recorder.record(Command.parse("TREE")); // skipped — not isRecorded()
    recorder.record(Command.parse("CLICK 'Login'")); // +1
    recorder.recordComment("a note"); // +1

    try std.testing.expectEqual(@as(u32, 3), recorder.lines);
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

    try std.testing.expect(recorder.isActive());
    try std.testing.expectEqualStrings(abs_path, recorder.path.?);

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

test "recordComment splits embedded newlines into separate comment lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = tmp.dir.createFile("multi.lp", .{ .read = true }) catch unreachable;
    var recorder: Self = .{
        .allocator = std.testing.allocator,
        .file = file,
        .path = null,
        .lines = 0,
        .buf = .init(std.testing.allocator),
    };
    defer recorder.deinit();

    // An attacker-controlled comment trying to smuggle a command must not
    // produce an executable line on replay.
    recorder.recordComment("note\nGOTO https://attacker\r\nmore");

    file.seekTo(0) catch unreachable;
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    try std.testing.expectEqualStrings(
        "# note\n# GOTO https://attacker\n# more\n",
        buf[0..n],
    );
}

test "record disables recorder on write failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Open the file read-only so writeAll fails with `error.NotOpenForWriting`.
    const file = blk: {
        _ = tmp.dir.createFile("ro.lp", .{}) catch unreachable;
        break :blk tmp.dir.openFile("ro.lp", .{ .mode = .read_only }) catch unreachable;
    };

    var recorder: Self = .{
        .allocator = std.testing.allocator,
        .file = file,
        .path = null,
        .lines = 0,
        .buf = .init(std.testing.allocator),
    };
    defer recorder.deinit();

    try std.testing.expect(recorder.isActive());
    recorder.record(Command.parse("GOTO https://example.com"));
    try std.testing.expect(!recorder.isActive());
    try std.testing.expectEqual(@as(u32, 0), recorder.lines);

    // Subsequent calls are silent no-ops, not silent successes.
    recorder.record(Command.parse("CLICK 'Login'"));
    recorder.recordComment("note");
    try std.testing.expectEqual(@as(u32, 0), recorder.lines);
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

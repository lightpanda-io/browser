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
const testing = @import("../testing.zig");
const Command = @import("command.zig").Command;

const Recorder = @This();

allocator: std.mem.Allocator,
/// Open append-mode handle while recording is active. Becomes null when a
/// write fails mid-session and the recorder self-disables; `isActive()`
/// reflects this.
file: ?std.fs.File,
/// Path of the active recording, owned by the Recorder.
path: []const u8,
/// Number of lines successfully appended since init. Bumped only on success
/// so callers see the actual file line count, not the attempt count.
lines: u32,
/// Reused between writes so each line doesn't alloc/free.
buf: std.Io.Writer.Allocating,
/// Reset per write — backs short-lived scrub allocations so the first
/// recorded command pays the page setup and the rest reuse the bump.
arena: std.heap.ArenaAllocator,

/// Append-open `sub_path` under `dir`, inserting a leading newline if the
/// file is non-empty.
pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, sub_path: []const u8) !Recorder {
    const owned_path = try allocator.dupe(u8, sub_path);
    errdefer allocator.free(owned_path);
    const file = try openForAppend(dir, sub_path);
    return .{
        .allocator = allocator,
        .file = file,
        .path = owned_path,
        .lines = 0,
        .buf = .init(allocator),
        .arena = .init(allocator),
    };
}

fn openForAppend(dir: std.fs.Dir, sub_path: []const u8) !std.fs.File {
    const f = try dir.createFile(sub_path, .{ .truncate = false });
    errdefer f.close();
    try f.seekFromEnd(0);
    const pos = try f.getPos();
    if (pos > 0) try f.writeAll("\n");
    return f;
}

pub fn deinit(self: *Recorder) void {
    self.buf.deinit();
    self.arena.deinit();
    if (self.file) |f| f.close();
    self.allocator.free(self.path);
}

pub fn isActive(self: *const Recorder) bool {
    return self.file != null;
}

pub fn record(self: *Recorder, cmd: Command) void {
    if (self.file == null) return;
    if (!cmd.isRecorded()) return;
    self.tryRecord(cmd) catch |err| self.disable(err);
}

fn tryRecord(self: *Recorder, cmd: Command) !void {
    self.buf.clearRetainingCapacity();
    try cmd.format(&self.buf.writer);
    try self.buf.writer.writeByte('\n');

    // Reverse-substitute any LP_* env-var values that snuck in as literals
    // (e.g. an agent that retyped a username it saw via getUrl) so the
    // recording stays portable instead of leaking the resolved secret.
    _ = self.arena.reset(.retain_capacity);
    const scrubbed = lp.tools.reverseSubstituteEnvVars(self.arena.allocator(), self.buf.written()) catch self.buf.written();

    try self.file.?.writeAll(scrubbed);
    self.lines += 1;
}

pub fn recordComment(self: *Recorder, comment: []const u8) void {
    if (self.file == null) return;
    self.tryRecordComment(comment) catch |err| self.disable(err);
}

fn tryRecordComment(self: *Recorder, comment: []const u8) !void {
    self.buf.clearRetainingCapacity();
    // Embedded newlines would smuggle an executable line into the script on
    // replay (e.g. `# foo\nGOTO https://attacker`). Emit each line of the
    // comment as its own `# ` line; strip lone CRs.
    var it = std.mem.splitScalar(u8, comment, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        try self.buf.writer.writeAll("# ");
        try self.buf.writer.writeAll(trimmed);
        try self.buf.writer.writeByte('\n');
    }
    try self.file.?.writeAll(self.buf.written());
    self.lines += 1;
}

/// Any failure along the record path — buffer-write OOM, scrub OOM, or file
/// write — flips the recorder to inactive so subsequent calls become silent
/// no-ops and `isActive()` reflects the stopped state.
fn disable(self: *Recorder, err: anyerror) void {
    log.warn(.app, "recording disabled", .{ .err = @errorName(err) });
    if (self.file) |f| {
        f.close();
        self.file = null;
    }
}

fn parseLine(arena: std.mem.Allocator, line: []const u8) Command {
    return Command.parse(arena, line) catch unreachable;
}

test "record writes state-mutating commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var recorder = try Recorder.init(std.testing.allocator, tmp.dir, "test.lp");
    defer recorder.deinit();

    recorder.record(parseLine(aa, "/goto https://example.com"));
    recorder.record(parseLine(aa, "/click selector='Login'"));
    recorder.record(parseLine(aa, "/tree"));
    recorder.record(parseLine(aa, "/waitForSelector '.dashboard'"));
    recorder.record(parseLine(aa, "/markdown"));
    recorder.record(parseLine(aa, "/scroll y=200"));
    recorder.record(parseLine(aa, "/hover selector='#menu'"));
    recorder.record(parseLine(aa, "/selectOption selector='#country' value='France'"));
    recorder.record(parseLine(aa, "/setChecked selector='#agree'"));
    recorder.record(parseLine(aa, "/setChecked selector='#newsletter' checked=false"));
    recorder.record(parseLine(aa, "/extract '{\"title\":\".title\"}'"));
    recorder.recordComment("LOGIN");

    const file = tmp.dir.openFile("test.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "/goto 'https://example.com'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/click selector='Login'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/waitForSelector '.dashboard'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/scroll y=200\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/hover selector='#menu'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/selectOption selector='#country' value='France'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/setChecked selector='#agree'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/setChecked selector='#newsletter' checked=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/extract '{\"title\":\".title\"}'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\n# LOGIN\n") != null);
    // Read-only tools (tree, markdown) are gated out by isRecorded().
    try std.testing.expect(std.mem.indexOf(u8, content, "/tree") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/markdown") == null);
}

test "record skips empty and comment lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var recorder = try Recorder.init(std.testing.allocator, tmp.dir, "test2.lp");
    defer recorder.deinit();

    recorder.record(parseLine(aa, ""));
    recorder.record(parseLine(aa, "   "));
    recorder.record(parseLine(aa, "# this is a comment"));
    recorder.record(parseLine(aa, "/goto https://example.com"));

    const file = tmp.dir.openFile("test2.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expectEqualStrings("/goto 'https://example.com'\n", content);
}

test "lines counter tracks successful appends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var recorder = try Recorder.init(std.testing.allocator, tmp.dir, "count.lp");
    defer recorder.deinit();

    recorder.record(parseLine(aa, "/goto https://example.com")); // +1
    recorder.record(parseLine(aa, "/tree")); // skipped — not isRecorded()
    recorder.record(parseLine(aa, "/click selector='Login'")); // +1
    recorder.recordComment("a note"); // +1

    try std.testing.expectEqual(@as(u32, 3), recorder.lines);
}

test "init appends to an existing file without truncating" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed a file with a prior line.
    {
        const seed = tmp.dir.createFile("script.lp", .{}) catch unreachable;
        defer seed.close();
        _ = seed.writeAll("/goto 'https://example.com'\n") catch unreachable;
    }

    var recorder = try Recorder.init(std.testing.allocator, tmp.dir, "script.lp");
    defer recorder.deinit();
    recorder.record(parseLine(aa, "/click selector='Login'"));

    try std.testing.expect(recorder.isActive());
    try std.testing.expectEqualStrings("script.lp", recorder.path);

    const file = tmp.dir.openFile("script.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "/goto 'https://example.com'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/click selector='Login'\n") != null);
    // The prior line must precede the appended line.
    const prior = std.mem.indexOf(u8, content, "/goto").?;
    const appended = std.mem.indexOf(u8, content, "/click").?;
    try std.testing.expect(prior < appended);
}

test "recordComment splits embedded newlines into separate comment lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var recorder = try Recorder.init(std.testing.allocator, tmp.dir, "multi.lp");
    defer recorder.deinit();

    // An attacker-controlled comment trying to smuggle a command must not
    // produce an executable line on replay.
    recorder.recordComment("note\n/goto https://attacker\r\nmore");

    const file = tmp.dir.openFile("multi.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    try std.testing.expectEqualStrings(
        "# note\n# /goto https://attacker\n# more\n",
        buf[0..n],
    );
}

test "record disables recorder on write failure" {
    const filter: testing.LogFilter = .init(&.{.app});
    defer filter.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Open the file read-only so writeAll fails with `error.NotOpenForWriting`.
    // Struct literal (not `init`) because only this test needs to inject a
    // read-only handle to exercise the failure path.
    const file = blk: {
        _ = tmp.dir.createFile("ro.lp", .{}) catch unreachable;
        break :blk tmp.dir.openFile("ro.lp", .{ .mode = .read_only }) catch unreachable;
    };

    var recorder: Recorder = .{
        .allocator = std.testing.allocator,
        .file = file,
        .path = try std.testing.allocator.dupe(u8, "test.lp"),
        .lines = 0,
        .buf = .init(std.testing.allocator),
        .arena = .init(std.testing.allocator),
    };
    defer recorder.deinit();

    var test_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer test_arena.deinit();
    const aa = test_arena.allocator();

    try std.testing.expect(recorder.isActive());
    recorder.record(parseLine(aa, "/goto https://example.com"));
    try std.testing.expect(!recorder.isActive());
    try std.testing.expectEqual(@as(u32, 0), recorder.lines);

    // Subsequent calls are silent no-ops, not silent successes.
    recorder.record(parseLine(aa, "/click selector='Login'"));
    recorder.recordComment("note");
    try std.testing.expectEqual(@as(u32, 0), recorder.lines);
}

test "init creates the file if missing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var recorder: Recorder = try .init(std.testing.allocator, tmp.dir, "fresh.lp");
    defer recorder.deinit();
    recorder.record(parseLine(aa, "/goto https://example.com"));

    const file = tmp.dir.openFile("fresh.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    try std.testing.expectEqualStrings("/goto 'https://example.com'\n", buf[0..n]);
}

test "record and parse: triple-quote round-trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var recorder = try Recorder.init(std.testing.allocator, tmp.dir, "triple.lp");
    defer recorder.deinit();

    const cmd_str = "/extract '{\n  \"title\": \"span.title\",\n  \"desc\": \"p.description\"\n}'";
    const original_cmd = parseLine(aa, cmd_str);
    recorder.record(original_cmd);

    const file = tmp.dir.openFile("triple.lp", .{}) catch unreachable;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch unreachable;
    const content = buf[0..n];

    var iter: Command.ScriptIterator = .init(aa, content);
    const entry = (try iter.next()).?;
    const parsed_cmd = entry.command;

    try std.testing.expectEqualStrings("extract", parsed_cmd.tool_call.name);

    const original_val = original_cmd.tool_call.args.?.object.get("schema").?.string;
    const parsed_val = parsed_cmd.tool_call.args.?.object.get("schema").?.string;
    try std.testing.expectEqualStrings(original_val, parsed_val);
}

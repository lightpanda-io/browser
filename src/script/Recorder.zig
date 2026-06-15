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

//! In-memory recorder backing the REPL `/save` command: it filters, formats,
//! and scrubs the session's commands into a JavaScript buffer, leaving
//! persistence timing to the caller.

const std = @import("std");
const lp = @import("lightpanda");
const Command = @import("command.zig").Command;

const Recorder = @This();

allocator: std.mem.Allocator,
/// Number of lines appended since the last reset. Bumped only on success.
lines: u32,
/// Whether `const page = new Page();` has been emitted yet. The first recorded
/// command emits it, then every call is a method on `page`.
page_declared: bool,
/// Accumulated JavaScript, returned verbatim by `bytes()`.
content: std.Io.Writer.Allocating,
/// Reused between writes so each line doesn't alloc/free.
buf: std.Io.Writer.Allocating,
/// Reset per write — backs short-lived scrub allocations.
arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) Recorder {
    return .{
        .allocator = allocator,
        .lines = 0,
        .page_declared = false,
        .content = .init(allocator),
        .buf = .init(allocator),
        .arena = .init(allocator),
    };
}

pub fn deinit(self: *Recorder) void {
    self.content.deinit();
    self.buf.deinit();
    self.arena.deinit();
}

pub fn bytes(self: *Recorder) []const u8 {
    return self.content.written();
}

pub fn reset(self: *Recorder) void {
    self.lines = 0;
    self.page_declared = false;
    self.content.clearRetainingCapacity();
    self.buf.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
}

pub fn record(self: *Recorder, cmd: Command) !void {
    if (!cmd.isRecorded()) return;
    self.buf.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    // `isRecorded` guarantees `.tool_call`. The page is born once, up front; every
    // recorded call is then a method on it — `goto` async, the rest sync.
    if (!self.page_declared) {
        try self.buf.writer.writeAll("const page = new Page();\n");
        self.page_declared = true;
    }
    if (cmd.tool_call.tool.isAsync()) try self.buf.writer.writeAll("await ");
    try self.buf.writer.writeAll("page.");
    try cmd.formatJs(self.arena.allocator(), &self.buf.writer);
    try self.buf.writer.writeByte('\n');
    try self.appendScrubbed();
}

pub fn recordComment(self: *Recorder, comment: []const u8) !void {
    self.buf.clearRetainingCapacity();
    try writeCommentLines(&self.buf.writer, comment);
    try self.appendScrubbed();
}

pub fn recordRaw(self: *Recorder, line: []const u8) !void {
    self.buf.clearRetainingCapacity();
    try self.buf.writer.writeAll(line);
    try self.buf.writer.writeByte('\n');
    try self.appendScrubbed();
}

fn appendScrubbed(self: *Recorder) !void {
    // Reverse-substitute any LP_* env-var values that snuck in as literals
    // (e.g. an agent that retyped a username it saw via getUrl) so the saved
    // script stays portable instead of leaking the resolved secret.
    _ = self.arena.reset(.retain_capacity);
    const scrubbed = try lp.tools.reverseSubstituteEnvVars(self.arena.allocator(), self.buf.written());
    try self.content.writer.writeAll(scrubbed);
    self.lines += @intCast(std.mem.count(u8, scrubbed, "\n"));
}

/// Emit each line of `comment` as its own `// ` line, stripping lone CRs.
/// Splitting on newlines is load-bearing: an embedded newline would otherwise
/// smuggle an executable line into the script on replay (e.g.
/// `// foo\ngoto("https://attacker")`).
fn writeCommentLines(w: *std.Io.Writer, comment: []const u8) !void {
    var it = std.mem.splitScalar(u8, comment, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        try w.writeAll("// ");
        try w.writeAll(trimmed);
        try w.writeByte('\n');
    }
}

fn parseLine(arena: std.mem.Allocator, line: []const u8) Command {
    return Command.parse(arena, line) catch unreachable;
}

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

test "record filters state-mutating commands and comments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var recorder: Recorder = .init(std.testing.allocator);
    defer recorder.deinit();

    try recorder.record(parseLine(aa, "/goto https://example.com"));
    try recorder.record(parseLine(aa, "/tree"));
    try recorder.record(parseLine(aa, "/click selector='Login'"));
    try recorder.recordComment("search for login");

    try std.testing.expectEqualStrings(
        "const page = new Page();\nawait page.goto(\"https://example.com\");\npage.click({ selector: \"Login\" });\n// search for login\n",
        recorder.bytes(),
    );
    try std.testing.expectEqual(@as(u32, 4), recorder.lines);

    recorder.reset();
    try std.testing.expectEqualStrings("", recorder.bytes());
    try std.testing.expectEqual(@as(u32, 0), recorder.lines);

    try recorder.record(parseLine(aa, "/scroll y=200"));
    try std.testing.expectEqualStrings("const page = new Page();\npage.scroll({ y: 200 });\n", recorder.bytes());
    try std.testing.expectEqual(@as(u32, 2), recorder.lines);
}

test "recordRaw writes the JS line verbatim" {
    var recorder: Recorder = .init(std.testing.allocator);
    defer recorder.deinit();

    try recorder.recordRaw("document.title");
    try recorder.recordRaw("window.scrollTo(0, 100)");

    try std.testing.expectEqualStrings("document.title\nwindow.scrollTo(0, 100)\n", recorder.bytes());
}

test "record emits multi-line extract as JavaScript" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var recorder: Recorder = .init(std.testing.allocator);
    defer recorder.deinit();

    const cmd_str = "/extract '{\n  \"title\": \"span.title\",\n  \"desc\": \"p.description\"\n}'";
    try recorder.record(parseLine(aa, cmd_str));

    try std.testing.expectEqualStrings(
        "const page = new Page();\npage.extract({ title: \"span.title\", desc: \"p.description\" });\n",
        recorder.bytes(),
    );
}

test "recordComment splits embedded newlines into separate comment lines" {
    var recorder: Recorder = .init(std.testing.allocator);
    defer recorder.deinit();

    // An attacker-controlled comment trying to smuggle a command must not
    // produce an executable line on replay.
    try recorder.recordComment("note\n/goto https://attacker\r\nmore");

    try std.testing.expectEqualStrings(
        "// note\n// /goto https://attacker\n// more\n",
        recorder.bytes(),
    );
}

test "recordComment scrubs literal LP_* values back to placeholders" {
    const var_name = "LP_RECORDER_COMMENT_TEST";
    const var_value = "topsecret";
    _ = setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = unsetenv(@constCast(var_name));

    var recorder: Recorder = .init(std.testing.allocator);
    defer recorder.deinit();

    try recorder.recordComment("a user noted that their password is topsecret");

    try std.testing.expectEqualStrings(
        "// a user noted that their password is $LP_RECORDER_COMMENT_TEST\n",
        recorder.bytes(),
    );
}

test "record scrubs literal LP_* values in JavaScript calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const var_name = "LP_RECORDER_COMMAND_TEST";
    const var_value = "secret-user";
    _ = setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = unsetenv(@constCast(var_name));

    var recorder: Recorder = .init(std.testing.allocator);
    defer recorder.deinit();

    try recorder.record(parseLine(aa, "/fill selector='#user' value='secret-user'"));
    try std.testing.expectEqualStrings(
        "const page = new Page();\npage.fill({ selector: \"#user\", value: \"$LP_RECORDER_COMMAND_TEST\" });\n",
        recorder.bytes(),
    );
}

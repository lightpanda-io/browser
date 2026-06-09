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

//! Pure helpers behind the agent's `/save`: parsing the command, validating and
//! picking filenames, writing script files, and shaping the synthesis prompt.
//! State-bearing orchestration (path resolution against the active session,
//! LLM synthesis turns) lives on `Agent`.

const std = @import("std");
const lp = @import("lightpanda");
const Schema = lp.Schema;

pub const Mode = enum { append, replace };

pub const Command = struct { filename: ?[]const u8, prompt: ?[]const u8 };

/// Split `/save` arguments into an optional filename and an optional trailing
/// natural-language prompt. A quoted leading token is always a filename; an
/// unquoted one is a filename only if it ends in `.js` (else the whole argument
/// is the prompt, and a name is chosen automatically).
pub fn parseCommand(rest: []const u8) !Command {
    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .filename = null, .prompt = null };

    if (trimmed[0] == '\'' or trimmed[0] == '"') {
        const quote = trimmed[0];
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, quote) orelse return error.UnterminatedQuote;
        const name = trimmed[1..end];
        try validateFilename(name);
        const rest_prompt = std.mem.trim(u8, trimmed[end + 1 ..], &std.ascii.whitespace);
        return .{ .filename = name, .prompt = if (rest_prompt.len == 0) null else rest_prompt };
    }

    const tok_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    const first = trimmed[0..tok_end];
    if (std.mem.endsWith(u8, first, ".js")) {
        try validateFilename(first);
        const rest_prompt = std.mem.trim(u8, trimmed[tok_end..], &std.ascii.whitespace);
        return .{ .filename = first, .prompt = if (rest_prompt.len == 0) null else rest_prompt };
    }
    return .{ .filename = null, .prompt = trimmed };
}

fn validateFilename(name: []const u8) !void {
    if (name.len == 0) return error.EmptyFilename;
    if (std.fs.path.isAbsolute(name)) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidFilename;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidFilename;
}

pub fn randomFilename(arena: std.mem.Allocator) ![]const u8 {
    for (0..100) |_| {
        const n = std.crypto.random.int(u64);
        const path = try std.fmt.allocPrint(arena, "session-{x}.js", .{n});
        if (!(try fileExists(path))) return path;
    }
    return error.NameCollision;
}

pub fn fileExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn writeContentFile(path: []const u8, content: []const u8, mode: Mode) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = mode == .replace });
    defer file.close();
    if (mode == .append) {
        try file.seekFromEnd(0);
        const pos = try file.getPos();
        if (pos > 0 and content.len > 0) try file.writeAll("\n");
    }
    try file.writeAll(content);
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writeAll("\n");
}

/// Document the recorded browser tools — the subset callable from a saved
/// script — with full descriptions, so the model gets each function's argument
/// dialect (e.g. `extract`'s schema format) without the tool schemas a no-tools
/// synthesis turn omits.
pub fn renderBuiltinCatalog(w: *std.Io.Writer) !void {
    for (Schema.all()) |s| {
        if (!s.tool.isRecorded()) continue;
        try w.print("\n{s}(", .{s.tool_name});
        for (s.required, 0..) |req, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(req);
        }
        try w.print("):\n{s}\n", .{s.description});
    }
}

/// Strip a surrounding ```` ```lang … ``` ```` markdown fence if the model
/// wrapped its output in one despite being told not to.
pub fn stripCodeFence(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, t, "```")) return t;
    const first_nl = std.mem.indexOfScalar(u8, t, '\n') orelse return t;
    const body = t[first_nl + 1 ..];
    const close = std.mem.lastIndexOf(u8, body, "```") orelse return std.mem.trim(u8, body, &std.ascii.whitespace);
    return std.mem.trim(u8, body[0..close], &std.ascii.whitespace);
}

test "parseCommand: filename only" {
    const r = try parseCommand("out.js");
    try std.testing.expectEqualStrings("out.js", r.filename.?);
    try std.testing.expect(r.prompt == null);
}

test "parseCommand: filename and prompt" {
    const r = try parseCommand("out.js summarize the login flow");
    try std.testing.expectEqualStrings("out.js", r.filename.?);
    try std.testing.expectEqualStrings("summarize the login flow", r.prompt.?);
}

test "parseCommand: quoted filename keeps trailing prompt" {
    const r = try parseCommand("\"my flow.js\"  do X");
    try std.testing.expectEqualStrings("my flow.js", r.filename.?);
    try std.testing.expectEqualStrings("do X", r.prompt.?);
}

test "parseCommand: prompt only when first token is not a .js name" {
    const r = try parseCommand("make a login script");
    try std.testing.expect(r.filename == null);
    try std.testing.expectEqualStrings("make a login script", r.prompt.?);
}

test "parseCommand: empty is all null" {
    const r = try parseCommand("   ");
    try std.testing.expect(r.filename == null);
    try std.testing.expect(r.prompt == null);
}

test "parseCommand: rejects path-like filenames" {
    try std.testing.expectError(error.InvalidFilename, parseCommand("../evil.js"));
    try std.testing.expectError(error.InvalidFilename, parseCommand("/tmp/x.js"));
    try std.testing.expectError(error.UnterminatedQuote, parseCommand("\"unclosed.js"));
}

test "renderBuiltinCatalog: lists recorded tools, omits read-only ones" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderBuiltinCatalog(&out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "goto(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "click(") != null);
    // tree/markdown are read-only and not callable from a saved script.
    try std.testing.expect(std.mem.indexOf(u8, text, "tree(") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "markdown(") == null);
}

test "stripCodeFence: unwraps a fenced block and passes plain text through" {
    try std.testing.expectEqualStrings("goto(\"x\");", stripCodeFence("```js\ngoto(\"x\");\n```"));
    try std.testing.expectEqualStrings("goto(\"x\");", stripCodeFence("goto(\"x\");"));
}

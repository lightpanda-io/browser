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

/// How a save treats an existing destination file. `update` is synthesis-only:
/// the model merges the saved script with the new material and returns the
/// complete result, so at the file level it writes like `replace`.
pub const Mode = enum { append, replace, update };

pub const Command = struct { filename: ?[]const u8, prompt: ?[]const u8 };

/// Split `/save` arguments positionally: the first (optionally quoted) token
/// is the filename — `.js` is appended when missing — and everything after it
/// is a natural-language prompt for the synthesizer. The filename may alias
/// `rest` or be arena-allocated.
pub fn parseCommand(arena: std.mem.Allocator, rest: []const u8) !Command {
    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .filename = null, .prompt = null };

    var name: []const u8 = undefined;
    var after: []const u8 = undefined;
    if (trimmed[0] == '\'' or trimmed[0] == '"') {
        const quote = trimmed[0];
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, quote) orelse return error.UnterminatedQuote;
        name = trimmed[1..end];
        after = trimmed[end + 1 ..];
    } else {
        const tok_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
        name = trimmed[0..tok_end];
        after = trimmed[tok_end..];
    }
    if (name.len == 0) return error.EmptyFilename;
    const prompt = std.mem.trim(u8, after, &std.ascii.whitespace);
    return .{
        .filename = try ensureJsExtension(arena, name),
        .prompt = if (prompt.len == 0) null else prompt,
    };
}

/// `name` with `.js` appended when missing; may alias `name` or be
/// arena-allocated. Shared by `/save` parsing and the one-shot `--save` flag
/// so the two paths can't drift.
pub fn ensureJsExtension(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, name, ".js")) return name;
    return std.mem.concat(arena, u8, &.{ name, ".js" });
}

pub fn randomFilename(arena: std.mem.Allocator) ![]const u8 {
    for (0..100) |_| {
        var n_bytes: [8]u8 = undefined;
        lp.io.random(&n_bytes);
        const n = std.mem.readInt(u64, &n_bytes, .little);
        const path = try std.fmt.allocPrint(arena, "session-{x}.js", .{n});
        if (!(try fileExists(path))) return path;
    }
    return error.NameCollision;
}

/// Read a previously saved script back for revision. Returns null when there
/// is nothing to feed the model: the file does not exist or is blank.
pub fn readScript(arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(lp.io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (std.mem.trim(u8, content, &std.ascii.whitespace).len == 0) return null;
    return content;
}

pub fn fileExists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(lp.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn writeContentFile(path: []const u8, content: []const u8, mode: Mode) !void {
    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{ .truncate = mode != .append });
    defer file.close(lp.io);
    var offset: u64 = 0;
    if (mode == .append) {
        offset = try file.length(lp.io);
        if (offset > 0 and content.len > 0) {
            try file.writePositionalAll(lp.io, "\n", offset);
            offset += 1;
        }
    }
    try file.writePositionalAll(lp.io, content, offset);
    offset += content.len;
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writePositionalAll(lp.io, "\n", offset);
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
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "out.js");
    try std.testing.expectEqualStrings("out.js", r.filename.?);
    try std.testing.expect(r.prompt == null);
}

test "ensureJsExtension appends only when missing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("out.js", try ensureJsExtension(arena.allocator(), "out"));
    try std.testing.expectEqualStrings("out.js", try ensureJsExtension(arena.allocator(), "out.js"));
    try std.testing.expectEqualStrings("a/b.thing.js", try ensureJsExtension(arena.allocator(), "a/b.thing"));
}

test "parseCommand: filename and prompt" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "out.js summarize the login flow");
    try std.testing.expectEqualStrings("out.js", r.filename.?);
    try std.testing.expectEqualStrings("summarize the login flow", r.prompt.?);
}

test "parseCommand: quoted filename keeps trailing prompt" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "\"my flow.js\"  do X");
    try std.testing.expectEqualStrings("my flow.js", r.filename.?);
    try std.testing.expectEqualStrings("do X", r.prompt.?);
}

test "parseCommand: appends .js to a bare name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "test");
    try std.testing.expectEqualStrings("test.js", r.filename.?);
    try std.testing.expect(r.prompt == null);
}

test "parseCommand: appends .js and keeps trailing prompt" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "test keep only the extraction");
    try std.testing.expectEqualStrings("test.js", r.filename.?);
    try std.testing.expectEqualStrings("keep only the extraction", r.prompt.?);
}

test "parseCommand: appends .js to a quoted name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "'my flow' do X");
    try std.testing.expectEqualStrings("my flow.js", r.filename.?);
    try std.testing.expectEqualStrings("do X", r.prompt.?);
}

test "parseCommand: empty is all null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseCommand(arena.allocator(), "   ");
    try std.testing.expect(r.filename == null);
    try std.testing.expect(r.prompt == null);
}

test "parseCommand: accepts path-like filenames" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("../evil.js", (try parseCommand(aa, "../evil.js")).filename.?);
    try std.testing.expectEqualStrings("/tmp/x.js", (try parseCommand(aa, "/tmp/x.js")).filename.?);
    try std.testing.expectEqualStrings("out/run.js", (try parseCommand(aa, "out/run")).filename.?);
    try std.testing.expectError(error.UnterminatedQuote, parseCommand(aa, "\"unclosed.js"));
}

test "stripCodeFence: unwraps a fenced block and passes plain text through" {
    try std.testing.expectEqualStrings("goto(\"x\");", stripCodeFence("```js\ngoto(\"x\");\n```"));
    try std.testing.expectEqualStrings("goto(\"x\");", stripCodeFence("goto(\"x\");"));
}

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

//! Iterates `.lp` content, gluing multi-line `'''…'''` blocks into a
//! single entry. Comments surface as `.comment` so the replay can attach
//! the preceding comment to the next executable line.

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const Schema = @import("Schema.zig");
const command = @import("command.zig");
const Command = command.Command;

const Iterator = @This();

allocator: std.mem.Allocator,
lines: std.mem.SplitIterator(u8, .scalar),
line_num: u32,

pub fn init(allocator: std.mem.Allocator, content: []const u8) Iterator {
    return .{
        .allocator = allocator,
        .lines = std.mem.splitScalar(u8, content, '\n'),
        .line_num = 0,
    };
}

pub const Entry = struct {
    line_num: u32,
    /// Trimmed opener line; use `raw_span` for splices that need the
    /// full block body.
    opener_line: []const u8,
    /// Slice of the original content buffer covering this entry,
    /// trailing newline included. Multi-line blocks span opener
    /// through closing triple-quote.
    raw_span: []const u8,
    command: Command,
};

pub fn next(self: *Iterator) command.ParseError!?Entry {
    while (self.lines.next()) |line| {
        self.line_num += 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const line_start = @intFromPtr(line.ptr) - @intFromPtr(self.lines.buffer.ptr);

        if (tryBlockOpener(trimmed)) |opener| {
            const start_line = self.line_num;
            const body = (try self.collectMultiLineBlock(opener.quote_type)) orelse {
                // Point the error at the opener line, not at EOF where
                // collectMultiLineBlock left line_num.
                self.line_num = start_line;
                return error.UnterminatedQuote;
            };
            // body is heap-owned by self.allocator (from toOwnedSlice); reclaim
            // it if any allocation between here and successful return fails.
            errdefer self.allocator.free(body);
            const span_end = self.lines.index orelse self.lines.buffer.len;

            var obj: std.json.ObjectMap = .init(self.allocator);
            if (opener.inline_args.len > 0) {
                const s = Schema.findByName(Schema.parseSlashCommand(trimmed).?.name).?;
                if (try s.parseInlineKv(self.allocator, opener.inline_args)) |v| if (v == .object) {
                    var it = v.object.iterator();
                    while (it.next()) |kv| try obj.put(kv.key_ptr.*, kv.value_ptr.*);
                };
            }
            try obj.put(opener.field, .{ .string = body });
            return .{
                .line_num = start_line,
                .opener_line = trimmed,
                .raw_span = self.lines.buffer[line_start..span_end],
                .command = .{ .tool_call = .{
                    .tool = opener.tool,
                    .args = .{ .object = obj },
                } },
            };
        }

        const span_end = self.lines.index orelse self.lines.buffer.len;
        return .{
            .line_num = self.line_num,
            .opener_line = trimmed,
            .raw_span = self.lines.buffer[line_start..span_end],
            .command = try Command.parse(self.allocator, trimmed),
        };
    }
    return null;
}

const BlockOpener = struct {
    tool: BrowserTool,
    field: []const u8,
    quote_type: Schema.QuoteType,
    /// Slice between the tool name and the triple-quote, e.g.
    /// `save=stories` in `/extract save=stories '''`.
    inline_args: []const u8,
};

fn tryBlockOpener(line: []const u8) ?BlockOpener {
    const split = Schema.parseSlashCommand(line) orelse return null;
    const s = Schema.findByName(split.name) orelse return null;
    if (!s.isMultiLineCapable()) return null;

    const rest = std.mem.trimRight(u8, split.rest, &std.ascii.whitespace);
    if (rest.len < 3) return null;
    const qt = Schema.QuoteType.fromLiteral(rest[rest.len - 3 ..]) orelse return null;
    const inline_args = std.mem.trim(u8, rest[0 .. rest.len - 3], &std.ascii.whitespace);
    return .{ .tool = s.tool, .field = s.required[0], .quote_type = qt, .inline_args = inline_args };
}

fn collectMultiLineBlock(self: *Iterator, quote_type: Schema.QuoteType) std.mem.Allocator.Error!?[]const u8 {
    const closer = quote_type.toLiteral();
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(self.allocator);
    var first = true;
    while (self.lines.next()) |line| {
        self.line_num += 1;
        const scrubbed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.eql(u8, scrubbed, closer)) {
            return try parts.toOwnedSlice(self.allocator);
        }
        if (!first) {
            try parts.append(self.allocator, '\n');
        } else {
            first = false;
        }
        // Trim CR only; full trim would clobber indentation.
        try parts.appendSlice(self.allocator, scrubbed);
    }
    return null;
}

// --- Tests ---

const testing = @import("../testing.zig");

test "basic slash commands" {
    const content =
        "/goto https://example.com\n" ++
        "/tree\n" ++
        "/click selector='Login'\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expect(e1.command == .tool_call);
    try testing.expectString("goto", e1.command.tool_call.name());

    const e2 = (try iter.next()).?;
    try testing.expectString("tree", e2.command.tool_call.name());

    const e3 = (try iter.next()).?;
    try testing.expectString("click", e3.command.tool_call.name());

    try testing.expect((try iter.next()) == null);
}

test "multi-line /eval block" {
    const content =
        "/goto https://x\n" ++
        "/eval '''\n" ++
        "const x = 1;\n" ++
        "return x;\n" ++
        "'''\n" ++
        "/tree\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expectString("goto", e1.command.tool_call.name());

    const e2 = (try iter.next()).?;
    try testing.expectString("eval", e2.command.tool_call.name());
    const script_value = e2.command.tool_call.args.?.object.get("script").?.string;
    try testing.expect(std.mem.indexOf(u8, script_value, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, script_value, "return x;") != null);

    const e3 = (try iter.next()).?;
    try testing.expectString("tree", e3.command.tool_call.name());

    try testing.expect((try iter.next()) == null);
}

test "comments preserve opener_line for context" {
    const content =
        "# Navigate\n" ++
        "/goto https://x\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expect(e1.command == .comment);
    try testing.expectString("# Navigate", e1.opener_line);

    const e2 = (try iter.next()).?;
    try testing.expect(e2.command == .tool_call);

    try testing.expect((try iter.next()) == null);
}

test "bare prose in script errors" {
    const content = "click the login button\n";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var iter: Iterator = .init(arena.allocator(), content);
    try testing.expectError(error.NotASlashCommand, iter.next());
}

test "UnterminatedQuote reports the opener line" {
    const content =
        "/goto https://x\n" ++
        "/eval '''\n" ++
        "  const x = 1;\n" ++
        "  return x;\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);
    _ = (try iter.next()).?;
    try testing.expectError(error.UnterminatedQuote, iter.next());
    try testing.expectEqual(@as(u32, 2), iter.line_num);
}

test "strips trailing CR from CRLF-authored bodies" {
    const content = "/goto https://x\r\n/extract '''\r\n{\"t\":\"h1\"}\r\n'''\r\n/click selector='#x'\r\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expectString("goto", e1.command.tool_call.name());

    const e2 = (try iter.next()).?;
    try testing.expectString("extract", e2.command.tool_call.name());
    try testing.expectString("{\"t\":\"h1\"}", e2.command.tool_call.args.?.object.get("schema").?.string);

    const e3 = (try iter.next()).?;
    try testing.expectString("click", e3.command.tool_call.name());

    try testing.expect((try iter.next()) == null);
}

test "preserves leading blank lines in multiline block" {
    const content =
        "/eval '''\n" ++
        "\n" ++
        "const x = 1;\n" ++
        "'''\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);
    const cmd = (try iter.next()).?;
    const script_value = cmd.command.tool_call.args.?.object.get("script").?.string;
    try testing.expectString("\nconst x = 1;", script_value);
}

test "ignores indented closer delimiters" {
    const content =
        "/eval '''\n" ++
        "  const x = '''foo''';\n" ++
        "'''\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Iterator = .init(arena.allocator(), content);
    const cmd = (try iter.next()).?;
    const script_value = cmd.command.tool_call.args.?.object.get("script").?.string;
    try testing.expectString("  const x = '''foo''';", script_value);
}

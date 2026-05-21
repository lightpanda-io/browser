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

//! PandaScript Command: a slash command, `#`-comment, or `/login` /
//! `/acceptCookies` LLM trigger. Bare prose is the REPL's job, not the parser's.
//! Multi-line `'''…'''` blocks are assembled by `ScriptIterator` before parse.

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");
const browser_tools = lp.tools;
const schema = @import("schema.zig");

pub const ParseError = schema.ParseError || error{
    NotASlashCommand,
};

pub const Command = union(enum) {
    tool_call: ToolCall,
    login: void,
    accept_cookies: void,
    comment: void,

    pub const ToolCall = struct {
        action: browser_tools.Action,
        args: ?std.json.Value,

        pub fn name(self: ToolCall) [:0]const u8 {
            return @tagName(self.action);
        }
    };

    fn schemaOf(tc: ToolCall) *const schema.SchemaInfo {
        return &schema.globalSchemas()[@intFromEnum(tc.action)];
    }

    pub fn isRecorded(self: Command) bool {
        return switch (self) {
            .comment => false,
            .login, .accept_cookies => true,
            .tool_call => |tc| blk: {
                const s = schemaOf(tc);
                if (!s.recorded) break :blk false;
                // backendNodeId is invalidated by any DOM mutation, so calls
                // using it aren't replayable.
                const args = tc.args orelse break :blk true;
                if (args == .object and args.object.contains("backendNodeId")) break :blk false;
                break :blk true;
            },
        };
    }

    pub fn producesData(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| schemaOf(tc).produces_data,
            else => false,
        };
    }

    pub fn needsLlm(self: Command) bool {
        return switch (self) {
            .login, .accept_cookies => true,
            else => false,
        };
    }

    pub fn canHeal(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| schemaOf(tc).can_heal,
            else => false,
        };
    }

    pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!Command {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return .{ .comment = {} };
        if (trimmed[0] == '#') return .{ .comment = {} };
        if (trimmed[0] != '/') return error.NotASlashCommand;

        const split = schema.splitNameRest(trimmed[1..]) orelse return error.MissingName;

        if (std.ascii.eqlIgnoreCase(split.name, "login")) {
            if (split.rest.len > 0) return error.MalformedKv;
            return .{ .login = {} };
        }
        if (std.ascii.eqlIgnoreCase(split.name, "acceptCookies")) {
            if (split.rest.len > 0) return error.MalformedKv;
            return .{ .accept_cookies = {} };
        }

        const s = schema.findSchema(schema.globalSchemas(), split.name) orelse return error.UnknownTool;
        const args = try schema.parseValue(arena, s, split.rest);
        return .{ .tool_call = .{ .action = s.action, .args = args } };
    }

    /// Canonical recorder format. Round-trips with `parse`.
    pub fn format(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .login => try writer.writeAll("/login"),
            .accept_cookies => try writer.writeAll("/acceptCookies"),
            .comment => try writer.writeAll("#"),
            .tool_call => |tc| try formatToolCall(tc, writer),
        }
    }

    /// `arguments` must outlive the returned Command — use `fromToolCallOwned`
    /// to deep-copy when it doesn't.
    pub fn fromToolCall(action: browser_tools.Action, arguments: ?std.json.Value) Command {
        return .{ .tool_call = .{ .action = action, .args = arguments } };
    }

    pub fn fromToolCallOwned(arena: std.mem.Allocator, action: browser_tools.Action, arguments: ?std.json.Value) std.mem.Allocator.Error!Command {
        const owned_args = if (arguments) |v| try zenai.json.dupeValue(arena, v) else null;
        return .{ .tool_call = .{ .action = action, .args = owned_args } };
    }

    /// Iterates `.lp` content, gluing multi-line `'''…'''` blocks into a
    /// single entry. Comments surface as `.comment` so the replay can attach
    /// the preceding comment to the next executable line.
    pub const ScriptIterator = struct {
        allocator: std.mem.Allocator,
        lines: std.mem.SplitIterator(u8, .scalar),
        line_num: u32,

        pub fn init(allocator: std.mem.Allocator, content: []const u8) ScriptIterator {
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

        pub fn next(self: *ScriptIterator) ParseError!?Entry {
            while (self.lines.next()) |line| {
                self.line_num += 1;
                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;

                const line_start = @intFromPtr(line.ptr) - @intFromPtr(self.lines.buffer.ptr);

                if (tryBlockOpener(trimmed)) |opener| {
                    const start_line = self.line_num;
                    const body = try self.collectMultiLineBlock(opener.quote_type);
                    const span_end = self.lines.index orelse self.lines.buffer.len;
                    if (body == null) return error.UnterminatedQuote;
                    var obj: std.json.ObjectMap = .init(self.allocator);
                    try obj.put(opener.field, .{ .string = body.? });
                    return .{
                        .line_num = start_line,
                        .opener_line = trimmed,
                        .raw_span = self.lines.buffer[line_start..span_end],
                        .command = .{ .tool_call = .{
                            .action = opener.action,
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
            action: browser_tools.Action,
            field: []const u8,
            quote_type: QuoteType,
        };

        fn tryBlockOpener(line: []const u8) ?BlockOpener {
            if (line.len < 2 or line[0] != '/') return null;
            const split = schema.splitNameRest(line[1..]) orelse return null;
            const s = schema.findSchema(schema.globalSchemas(), split.name) orelse return null;
            if (!s.isMultiLineCapable()) return null;
            const qt = QuoteType.fromLiteral(split.rest) orelse return null;
            return .{ .action = s.action, .field = s.required[0], .quote_type = qt };
        }

        fn collectMultiLineBlock(self: *ScriptIterator, quote_type: QuoteType) std.mem.Allocator.Error!?[]const u8 {
            const closer = quote_type.toLiteral();
            var parts: std.ArrayList(u8) = .empty;
            defer parts.deinit(self.allocator);
            while (self.lines.next()) |line| {
                self.line_num += 1;
                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                if (std.mem.eql(u8, trimmed, closer)) {
                    return try parts.toOwnedSlice(self.allocator);
                }
                if (parts.items.len > 0) {
                    try parts.append(self.allocator, '\n');
                }
                // Trim CR only; full trim would clobber indentation.
                try parts.appendSlice(self.allocator, std.mem.trimRight(u8, line, "\r"));
            }
            return null;
        }
    };
};

// --- Formatting ---

fn formatToolCall(tc: Command.ToolCall, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const s = &schema.globalSchemas()[@intFromEnum(tc.action)];
    try writer.writeByte('/');
    try writer.writeAll(s.tool_name);

    const args_val = tc.args orelse return;
    if (args_val != .object) return;
    const args = args_val.object;
    if (args.count() == 0) return;

    // Positional form `/goto '<url>'` only when args reduce to the single
    // required field; extra fields force kv so recordings stay unambiguous.
    var positional_emitted: ?[]const u8 = null;
    {
        const has_one_required = s.required.len == 1;
        var visible: usize = 0;
        var it_v = args.iterator();
        while (it_v.next()) |entry| {
            if (isDefaultTrueBool(s, entry.key_ptr.*, entry.value_ptr.*)) continue;
            visible += 1;
        }
        if (has_one_required and visible == 1) blk: {
            const req_name = s.required[0];
            const v = args.get(req_name) orelse break :blk;
            if (v != .string) break :blk;
            try writer.writeByte(' ');
            try formatString(writer, v.string);
            positional_emitted = req_name;
        }
    }

    var it = args.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (positional_emitted) |p| if (std.mem.eql(u8, key, p)) continue;
        if (isDefaultTrueBool(s, key, entry.value_ptr.*)) continue;
        try writer.writeByte(' ');
        try writer.writeAll(key);
        try writer.writeByte('=');
        try formatKvValue(writer, entry.value_ptr.*);
    }
}

fn isDefaultTrueBool(s: *const schema.SchemaInfo, key: []const u8, v: std.json.Value) bool {
    return v == .bool and v.bool and s.isFieldDefaultTrue(key);
}

fn formatString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (std.mem.indexOfScalar(u8, s, '\n') != null) {
        const q = QuoteType.pickFor(s).toLiteral();
        try writer.writeAll(q);
        try writer.writeByte('\n');
        try writer.writeAll(s);
        try writer.writeByte('\n');
        try writer.writeAll(q);
        return;
    }
    try writeQuoted(writer, s);
}

fn formatKvValue(writer: *std.Io.Writer, v: std.json.Value) std.Io.Writer.Error!void {
    switch (v) {
        .string => |s| try formatString(writer, s),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
        else => std.json.Stringify.value(v, .{}, writer) catch return error.WriteFailed,
    }
}

fn writeQuoted(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const has_single = std.mem.indexOfScalar(u8, s, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, s, '"') != null;

    if (has_single and has_double) {
        const q = QuoteType.pickFor(s).toLiteral();
        try writer.writeAll(q);
        try writer.writeAll(s);
        try writer.writeAll(q);
        return;
    }
    const q: u8 = if (has_single) '"' else '\'';
    try writer.writeByte(q);
    try writer.writeAll(s);
    try writer.writeByte(q);
}

// --- Quoting primitives (kept for ScriptIterator block-opener detection) ---

pub const QuoteType = enum {
    triple_double,
    triple_single,

    pub fn fromLiteral(s: []const u8) ?QuoteType {
        return if (s.len == 3) fromPrefix(s) else null;
    }

    pub fn fromPrefix(s: []const u8) ?QuoteType {
        if (std.mem.startsWith(u8, s, "\"\"\"")) return .triple_double;
        if (std.mem.startsWith(u8, s, "'''")) return .triple_single;
        return null;
    }

    pub fn toLiteral(self: QuoteType) []const u8 {
        return switch (self) {
            .triple_double => "\"\"\"",
            .triple_single => "'''",
        };
    }

    /// Default `'''`; swaps to `"""` only when the body already contains `'''`.
    pub fn pickFor(body: []const u8) QuoteType {
        if (std.mem.indexOf(u8, body, "'''") != null) return .triple_double;
        return .triple_single;
    }
};

// --- Tests ---

const testing = std.testing;

test "parse: blank and # lines are comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Command.parse(arena.allocator(), "")) == .comment);
    try testing.expect((try Command.parse(arena.allocator(), "   ")) == .comment);
    try testing.expect((try Command.parse(arena.allocator(), "# foo")) == .comment);
}

test "parse: bare prose errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotASlashCommand, Command.parse(arena.allocator(), "click the login button"));
    try testing.expectError(error.NotASlashCommand, Command.parse(arena.allocator(), "goto https://x"));
}

test "parse: /login and /acceptCookies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Command.parse(arena.allocator(), "/login")) == .login);
    try testing.expect((try Command.parse(arena.allocator(), "/acceptCookies")) == .accept_cookies);
}

test "parse: /goto positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/goto https://example.com");
    try testing.expect(cmd == .tool_call);
    try testing.expectEqualStrings("goto", cmd.tool_call.name());
    try testing.expectEqualStrings("https://example.com", cmd.tool_call.args.?.object.get("url").?.string);
}

test "parse: /click rejects positional (zero required fields)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.PositionalNotAllowed, Command.parse(arena.allocator(), "/click 'Login'"));
    const cmd = try Command.parse(arena.allocator(), "/click selector='Login'");
    try testing.expectEqualStrings("Login", cmd.tool_call.args.?.object.get("selector").?.string);
}

test "parse: /scroll y=200" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/scroll y=200");
    try testing.expectEqual(@as(i64, 200), cmd.tool_call.args.?.object.get("y").?.integer);
}

test "parse: /setChecked omits checked (default-true)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/setChecked selector='#agree'");
    try testing.expectEqualStrings("#agree", cmd.tool_call.args.?.object.get("selector").?.string);
    try testing.expect(cmd.tool_call.args.?.object.get("checked").?.bool);
}

test "parse: unknown tool errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnknownTool, Command.parse(arena.allocator(), "/bogus"));
}

test "format: /goto round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/goto https://example.com");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectEqualStrings("/goto 'https://example.com'", aw.written());
}

test "format: /click stays kv (zero required fields)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/click selector='Login'");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectEqualStrings("/click selector='Login'", aw.written());
}

test "format: /eval emits triple-quote block for multi-line script" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const args = blk: {
        var obj: std.json.ObjectMap = .init(arena.allocator());
        try obj.put("script", .{ .string = "const x = 1;\nreturn x;" });
        break :blk std.json.Value{ .object = obj };
    };
    const cmd: Command = .{ .tool_call = .{ .action = .eval, .args = args } };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectEqualStrings("/eval '''\nconst x = 1;\nreturn x;\n'''", aw.written());
}

test "format: /setChecked omits checked=true (matches default)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/setChecked selector='#agree' checked=true");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectEqualStrings("/setChecked selector='#agree'", aw.written());
}

test "format: /setChecked keeps checked=false (non-default)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/setChecked selector='#x' checked=false");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectEqualStrings("/setChecked selector='#x' checked=false", aw.written());
}

test "format: /login and /acceptCookies" {
    var aw1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw1.deinit();
    try (Command{ .login = {} }).format(&aw1.writer);
    try testing.expectEqualStrings("/login", aw1.written());

    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try (Command{ .accept_cookies = {} }).format(&aw2.writer);
    try testing.expectEqualStrings("/acceptCookies", aw2.written());
}

test "isRecorded / canHeal / producesData via tool flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const goto = try Command.parse(arena.allocator(), "/goto https://x");
    try testing.expect(goto.isRecorded());
    try testing.expect(!goto.canHeal()); // navigation excluded from heal
    try testing.expect(!goto.producesData());

    const tree = try Command.parse(arena.allocator(), "/tree");
    try testing.expect(!tree.isRecorded());
    try testing.expect(tree.producesData());

    const login: Command = .{ .login = {} };
    try testing.expect(login.isRecorded());
    try testing.expect(!login.canHeal());
}

test "ScriptIterator: basic slash commands" {
    const content =
        "/goto https://example.com\n" ++
        "/tree\n" ++
        "/click selector='Login'\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Command.ScriptIterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expect(e1.command == .tool_call);
    try testing.expectEqualStrings("goto", e1.command.tool_call.name());

    const e2 = (try iter.next()).?;
    try testing.expectEqualStrings("tree", e2.command.tool_call.name());

    const e3 = (try iter.next()).?;
    try testing.expectEqualStrings("click", e3.command.tool_call.name());

    try testing.expect((try iter.next()) == null);
}

test "ScriptIterator: multi-line /eval block" {
    const content =
        "/goto https://x\n" ++
        "/eval '''\n" ++
        "const x = 1;\n" ++
        "return x;\n" ++
        "'''\n" ++
        "/tree\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Command.ScriptIterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expectEqualStrings("goto", e1.command.tool_call.name());

    const e2 = (try iter.next()).?;
    try testing.expectEqualStrings("eval", e2.command.tool_call.name());
    const script_value = e2.command.tool_call.args.?.object.get("script").?.string;
    try testing.expect(std.mem.indexOf(u8, script_value, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, script_value, "return x;") != null);

    const e3 = (try iter.next()).?;
    try testing.expectEqualStrings("tree", e3.command.tool_call.name());

    try testing.expect((try iter.next()) == null);
}

test "ScriptIterator: comments preserve opener_line for context" {
    const content =
        "# Navigate\n" ++
        "/goto https://x\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Command.ScriptIterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expect(e1.command == .comment);
    try testing.expectEqualStrings("# Navigate", e1.opener_line);

    const e2 = (try iter.next()).?;
    try testing.expect(e2.command == .tool_call);

    try testing.expect((try iter.next()) == null);
}

test "ScriptIterator: bare prose in script errors" {
    const content = "click the login button\n";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var iter: Command.ScriptIterator = .init(arena.allocator(), content);
    try testing.expectError(error.NotASlashCommand, iter.next());
}

test "ScriptIterator: strips trailing CR from CRLF-authored bodies" {
    const content = "/goto https://x\r\n/extract '''\r\n{\"t\":\"h1\"}\r\n'''\r\n/click selector='#x'\r\n";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var iter: Command.ScriptIterator = .init(arena.allocator(), content);

    const e1 = (try iter.next()).?;
    try testing.expectEqualStrings("goto", e1.command.tool_call.name());

    const e2 = (try iter.next()).?;
    try testing.expectEqualStrings("extract", e2.command.tool_call.name());
    try testing.expectEqualStrings("{\"t\":\"h1\"}", e2.command.tool_call.args.?.object.get("schema").?.string);

    const e3 = (try iter.next()).?;
    try testing.expectEqualStrings("click", e3.command.tool_call.name());

    try testing.expect((try iter.next()) == null);
}

test "fromToolCall: builds a tool_call Command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var obj: std.json.ObjectMap = .init(arena.allocator());
    try obj.put("url", .{ .string = "https://x" });
    const cmd = Command.fromToolCall(.goto, .{ .object = obj });
    try testing.expect(cmd == .tool_call);
    try testing.expectEqualStrings("goto", cmd.tool_call.name());
}

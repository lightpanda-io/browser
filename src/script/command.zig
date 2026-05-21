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

//! PandaScript Command — one line of a `.lp` script.
//!
//! Post-unification PandaScript is just slash commands plus two LLM triggers
//! and comments. Natural language is NOT part of the language: a line that
//! is neither a slash command, a `#`-comment, nor blank is a parse error.
//! Bare prose → LLM happens only in the live REPL when an LLM is configured,
//! and is handled there, not here.
//!
//! `Command.parse` consumes a single line and returns a `Command`. Multi-line
//! `/eval '''…'''` / `/extract '''…'''` blocks live in `ScriptIterator`,
//! which assembles the body before calling `parse` on the synthesized line.

const std = @import("std");
const lp = @import("lightpanda");
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
        /// Slice into the schema table — lives forever, no dupe required.
        name: []const u8,
        /// Arena-owned. `null` for tools with no args (e.g. `/getCookies`).
        args: ?std.json.Value,
    };

    pub fn isRecorded(self: Command) bool {
        return switch (self) {
            .comment => false,
            .login, .accept_cookies => true,
            .tool_call => |tc| blk: {
                if (!recordedByName(tc.name)) break :blk false;
                // backendNodeId-based calls aren't replayable (the id is
                // invalidated by any DOM mutation), so keep them out of the
                // recording even when the tool itself is recordable.
                const args = tc.args orelse break :blk true;
                if (args == .object and args.object.contains("backendNodeId")) break :blk false;
                break :blk true;
            },
        };
    }

    pub fn producesData(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| producesDataByName(tc.name),
            else => false,
        };
    }

    pub fn needsLlm(self: Command) bool {
        return switch (self) {
            .login, .accept_cookies => true,
            else => false,
        };
    }

    /// Self-heal must only patch the current page; navigation is excluded
    /// even though `/goto` is recorded. The decision lives on the per-tool
    /// `can_heal` flag in `tool_defs`; here it's just a lookup.
    pub fn canHeal(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| canHealByName(tc.name),
            else => false,
        };
    }

    /// Parse one trimmed line. Branch order: blank/`#` → `.comment`;
    /// `/login` and `/acceptCookies` short-circuit to their meta variants;
    /// any other `/<name>` resolves the schema and parses args; anything
    /// else returns `error.NotASlashCommand`. Bare-prose-to-LLM is the REPL's
    /// job, not the parser's.
    pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!Command {
        return parseWithSchemas(arena, line, schema.globalSchemas());
    }

    /// Same as `parse` but lets callers inject a different schema set —
    /// the agent uses its own arena-backed cache to avoid double-parsing.
    pub fn parseWithSchemas(arena: std.mem.Allocator, line: []const u8, schemas: []const schema.SchemaInfo) ParseError!Command {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return .{ .comment = {} };
        if (trimmed[0] == '#') return .{ .comment = {} };
        if (trimmed[0] != '/') return error.NotASlashCommand;

        const split = schema.splitNameRest(trimmed[1..]) orelse return error.MissingName;

        // LLM-trigger meta commands. They live in the language (recordable)
        // but execution happens in the REPL/runScript layer.
        if (std.ascii.eqlIgnoreCase(split.name, "login")) {
            if (split.rest.len > 0) return error.MalformedKv;
            return .{ .login = {} };
        }
        if (std.ascii.eqlIgnoreCase(split.name, "acceptCookies")) {
            if (split.rest.len > 0) return error.MalformedKv;
            return .{ .accept_cookies = {} };
        }

        const s = schema.findSchema(schemas, split.name) orelse return error.UnknownTool;
        const args = try schema.parseValue(arena, s, split.rest);
        return .{ .tool_call = .{ .name = s.tool_name, .args = args } };
    }

    /// Round-trips with `parse` for the canonical recorder output. Single-
    /// required-field tools emit positional + quoted (`/click '#login'`);
    /// everything else emits `/name key=value ...`. Multi-line string values
    /// use `'''…'''` blocks. Default-true booleans are omitted when matching.
    pub fn format(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .login => try writer.writeAll("/login"),
            .accept_cookies => try writer.writeAll("/acceptCookies"),
            .comment => try writer.writeAll("#"),
            .tool_call => |tc| try formatToolCall(tc, writer),
        }
    }

    /// Construct a Command for a tool call. Used by recording paths that
    /// already have the `(name, args)` shape (MCP dispatch, LLM tool calls).
    /// The `name` slice must live as long as the Command (typically a
    /// `tool_defs`-owned slice, which is process-lifetime).
    pub fn fromToolCall(tool_name: []const u8, arguments: ?std.json.Value) Command {
        return .{ .tool_call = .{ .name = tool_name, .args = arguments } };
    }

    /// Walks `.lp` content line-by-line, gluing multi-line `'''…'''` blocks
    /// (today: `/eval`, `/extract`; any single-required-string-field tool
    /// qualifies) into a single entry. Comments and blank lines surface as
    /// `.comment` entries so the script replay can attach prefacing comments
    /// to the next executable line.
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
            /// Trimmed opener line — the only line for single-line entries,
            /// the `/eval '''` / `/extract '''` opener for blocks. Display-only
            /// (errors, REPL echo, heal-comment headers); use `raw_span` for
            /// splices that need the full block body.
            opener_line: []const u8,
            /// The full slice of the original content buffer covering this entry,
            /// including trailing newline(s). For multi-line blocks this spans
            /// from the opener through the closing triple-quote line.
            raw_span: []const u8,
            command: Command,
        };

        pub fn next(self: *ScriptIterator) ParseError!?Entry {
            const schemas = schema.globalSchemas();

            while (self.lines.next()) |line| {
                self.line_num += 1;
                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;

                const line_start = @intFromPtr(line.ptr) - @intFromPtr(self.lines.buffer.ptr);

                if (try self.tryBlockOpener(trimmed, schemas)) |opener| {
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
                            .name = opener.tool_name,
                            .args = .{ .object = obj },
                        } },
                    };
                }

                const span_end = self.lines.index orelse self.lines.buffer.len;
                return .{
                    .line_num = self.line_num,
                    .opener_line = trimmed,
                    .raw_span = self.lines.buffer[line_start..span_end],
                    .command = try Command.parseWithSchemas(self.allocator, trimmed, schemas),
                };
            }
            return null;
        }

        const BlockOpener = struct {
            tool_name: []const u8,
            field: []const u8,
            quote_type: QuoteType,
        };

        /// `/eval '''` or `/extract '''` (and any other single-required-string-field
        /// tool followed by a bare triple-quote token).
        fn tryBlockOpener(_: *ScriptIterator, line: []const u8, schemas: []const schema.SchemaInfo) ParseError!?BlockOpener {
            if (line.len < 2 or line[0] != '/') return null;
            const split = schema.splitNameRest(line[1..]) orelse return null;
            const s = schema.findSchema(schemas, split.name) orelse return null;
            if (!s.isMultiLineCapable()) return null;
            const qt = QuoteType.fromLiteral(split.rest) orelse return null;
            return .{ .tool_name = s.tool_name, .field = s.required[0], .quote_type = qt };
        }

        fn collectMultiLineBlock(self: *ScriptIterator, quote_type: QuoteType) std.mem.Allocator.Error!?[]const u8 {
            const closer = quote_type.toLiteral();
            var parts: std.ArrayList(u8) = .empty;
            // toOwnedSlice empties `parts`, so this defer is a no-op on success.
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
                // Strip trailing CR only — full trim would clobber indentation.
                try parts.appendSlice(self.allocator, std.mem.trimRight(u8, line, "\r"));
            }
            return null;
        }
    };
};

// --- Recording-policy lookups (delegate to schema flags) ---

fn recordedByName(name: []const u8) bool {
    for (lp.tools.tool_defs) |td| {
        if (std.mem.eql(u8, td.name, name)) return td.recorded;
    }
    return false;
}

fn canHealByName(name: []const u8) bool {
    for (lp.tools.tool_defs) |td| {
        if (std.mem.eql(u8, td.name, name)) return td.can_heal;
    }
    return false;
}

fn producesDataByName(name: []const u8) bool {
    for (lp.tools.tool_defs) |td| {
        if (std.mem.eql(u8, td.name, name)) return td.produces_data;
    }
    return false;
}

// --- Formatting ---

fn formatToolCall(tc: Command.ToolCall, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const schemas = schema.globalSchemas();
    const s_opt = schema.findSchema(schemas, tc.name);
    try writer.writeByte('/');
    try writer.writeAll(tc.name);

    const args_val = tc.args orelse return;
    if (args_val != .object) return;
    const args = args_val.object;
    if (args.count() == 0) return;

    // Emit positional form only when the args reduce to the single required
    // field: `/goto '<url>'`, `/click '<sel>'`, `/extract '<schema>'`. As soon
    // as there are extra fields (`/selectOption selector=... value=...`,
    // `/setChecked selector=... checked=false`), fall back to kv so the
    // recording stays unambiguous.
    var positional_emitted: ?[]const u8 = null;
    if (s_opt) |s| {
        const has_one_required = s.required.len == 1;
        // Count visible fields, ignoring default-true booleans that we'd skip
        // in the kv pass below — they don't make the args "non-trivial".
        var visible: usize = 0;
        var it_v = args.iterator();
        while (it_v.next()) |entry| {
            if (isDefaultTrueBool(s, entry.key_ptr.*, entry.value_ptr.*)) continue;
            visible += 1;
        }
        if (has_one_required and visible == 1) {
            const req_name = s.required[0];
            if (args.get(req_name)) |v| {
                if (v == .string) {
                    try writer.writeByte(' ');
                    try formatPositional(writer, v.string);
                    positional_emitted = req_name;
                }
            }
        }
    }

    // Emit kv for every key not already used as the positional, *and* skip
    // default-true booleans so `/setChecked selector='#a'` round-trips.
    var it = args.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (positional_emitted) |p| if (std.mem.eql(u8, key, p)) continue;
        if (s_opt) |s| if (isDefaultTrueBool(s, key, entry.value_ptr.*)) continue;
        try writer.writeByte(' ');
        try writer.writeAll(key);
        try writer.writeByte('=');
        try formatKvValue(writer, entry.value_ptr.*);
    }
}

fn isDefaultTrueBool(s: *const schema.SchemaInfo, key: []const u8, v: std.json.Value) bool {
    if (v != .bool or !v.bool) return false;
    for (s.fields) |f| {
        if (std.mem.eql(u8, f.name, key)) return f.default_true;
    }
    return false;
}

/// Positional and kv string emission share the same quoting rules — strings
/// always quoted (or triple-quoted when they contain newlines) so a recorded
/// line is unambiguous regardless of the value's content.
fn formatPositional(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    return formatString(writer, s);
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

/// Kv-value emission: strings via `formatString`; numbers/bools bare.
fn formatKvValue(writer: *std.Io.Writer, v: std.json.Value) std.Io.Writer.Error!void {
    switch (v) {
        .string => |s| try formatString(writer, s),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
        else => {
            // Arrays/objects emit as compact JSON.
            std.json.Stringify.value(v, .{}, writer) catch return error.WriteFailed;
        },
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

    /// Pick the triple-quote delimiter that does not collide with `body`.
    /// Defaults to `triple_single`; swaps to `triple_double` only when the
    /// body already contains `'''`.
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
    try testing.expectEqualStrings("goto", cmd.tool_call.name);
    try testing.expectEqualStrings("https://example.com", cmd.tool_call.args.?.object.get("url").?.string);
}

test "parse: /click positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // click has zero required fields — `/click 'Login'` would be PositionalNotAllowed.
    try testing.expectError(error.PositionalNotAllowed, Command.parse(arena.allocator(), "/click 'Login'"));
    // The valid form is kv.
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
    // Recorder always quotes string values for unambiguous round-trips.
    try testing.expectEqualStrings("/goto 'https://example.com'", aw.written());
}

test "format: /click emits positional for single-required tools? no — click has zero required" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/click selector='Login'");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    // Click has zero required fields, so kv form is canonical.
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
    const cmd: Command = .{ .tool_call = .{ .name = "eval", .args = args } };

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
    try testing.expectEqualStrings("goto", e1.command.tool_call.name);

    const e2 = (try iter.next()).?;
    try testing.expectEqualStrings("tree", e2.command.tool_call.name);

    const e3 = (try iter.next()).?;
    try testing.expectEqualStrings("click", e3.command.tool_call.name);

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
    try testing.expectEqualStrings("goto", e1.command.tool_call.name);

    const e2 = (try iter.next()).?;
    try testing.expectEqualStrings("eval", e2.command.tool_call.name);
    const script_value = e2.command.tool_call.args.?.object.get("script").?.string;
    try testing.expect(std.mem.indexOf(u8, script_value, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, script_value, "return x;") != null);

    const e3 = (try iter.next()).?;
    try testing.expectEqualStrings("tree", e3.command.tool_call.name);

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
    try testing.expectEqualStrings("goto", e1.command.tool_call.name);

    const e2 = (try iter.next()).?;
    try testing.expectEqualStrings("extract", e2.command.tool_call.name);
    try testing.expectEqualStrings("{\"t\":\"h1\"}", e2.command.tool_call.args.?.object.get("schema").?.string);

    const e3 = (try iter.next()).?;
    try testing.expectEqualStrings("click", e3.command.tool_call.name);

    try testing.expect((try iter.next()) == null);
}

test "fromToolCall: builds a tool_call Command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var obj: std.json.ObjectMap = .init(arena.allocator());
    try obj.put("url", .{ .string = "https://x" });
    const cmd = Command.fromToolCall("goto", .{ .object = obj });
    try testing.expect(cmd == .tool_call);
    try testing.expectEqualStrings("goto", cmd.tool_call.name);
}

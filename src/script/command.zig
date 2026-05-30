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

//! PandaScript Command: slash command, `#`-comment, or `/login` /
//! `/acceptCookies` LLM trigger. Multi-line `'''…'''` blocks are
//! assembled by `script.Iterator` before parse.

const std = @import("std");
const lp = @import("lightpanda");
const BrowserTool = lp.tools.Tool;
const Schema = @import("Schema.zig");

pub const ParseError = Schema.ParseError || error{
    NotASlashCommand,
};

pub const Command = union(enum) {
    tool_call: ToolCall,
    login: void,
    acceptCookies: void,
    comment: void,

    /// Union tags that fire an LLM trigger. Tag names match the wire-format
    /// slash command, so `@tagName` is the single source of truth.
    pub const llm_tags: []const std.meta.Tag(Command) = &.{ .login, .acceptCookies };

    pub const ToolCall = struct {
        tool: BrowserTool,
        args: ?std.json.Value,

        pub fn name(self: ToolCall) [:0]const u8 {
            return @tagName(self.tool);
        }

        fn schema(self: ToolCall) *const Schema {
            return &Schema.all()[@intFromEnum(self.tool)];
        }

        /// Skip the line when the recorded form would not round-trip:
        /// - no `selector` AND (tool needs one OR only locator is the
        ///   ephemeral `backendNodeId`);
        /// - a string field can't be quoted unambiguously.
        fn isRecorded(self: ToolCall) bool {
            if (!self.tool.isRecorded()) return false;
            const s = self.schema();
            const args = self.args orelse return s.required.len == 0 and !self.tool.needsLocator();
            if (args != .object) return !self.tool.needsLocator();

            const has_selector = args.object.contains("selector");
            if (!has_selector and (self.tool.needsLocator() or args.object.contains("backendNodeId"))) return false;

            const visible = s.visibleArgCount(args.object);
            const positional = s.required.len == 1 and visible == 1 and s.isSinglePositional(args.object);

            var it = args.object.iterator();
            while (it.next()) |entry| {
                if (s.skipForFormat(entry.key_ptr.*, entry.value_ptr.*)) continue;
                if (entry.value_ptr.* != .string) continue;
                const is_body = positional and std.mem.eql(u8, entry.key_ptr.*, s.required[0]);
                if (!Schema.quotableInline(entry.value_ptr.string, is_body)) return false;
            }
            return true;
        }

        /// Canonical recorder format. Round-trips with `Command.parse`.
        fn format(self: ToolCall, writer: *std.Io.Writer) (std.Io.Writer.Error || error{AmbiguousQuoting})!void {
            const s = self.schema();
            try writer.writeByte('/');
            try writer.writeAll(s.tool_name);

            const args_val = self.args orelse return;
            if (args_val != .object) return;
            const args = args_val.object;
            if (args.count() == 0) return;

            const visible = s.visibleArgCount(args);
            const positional = s.required.len == 1 and visible == 1 and s.isSinglePositional(args);

            if (positional) {
                const v = args.get(s.required[0]).?;
                try writer.writeByte(' ');
                try Schema.writeBodyString(writer, v.string);
                return;
            }

            // Iterate the schema (not the ObjectMap) so the line order is
            // stable across providers — MCP scriptHeal looks lines up
            // verbatim.
            for (s.fields) |f| {
                const v = args.get(f.name) orelse continue;
                if (f.skipForFormat(v)) continue;
                try writer.writeByte(' ');
                try writer.writeAll(f.name);
                try writer.writeByte('=');
                try Schema.writeInlineValue(writer, v);
            }
        }
    };

    pub fn isRecorded(self: Command) bool {
        return switch (self) {
            .comment => false,
            .login, .acceptCookies => true,
            .tool_call => |tc| tc.isRecorded(),
        };
    }

    pub fn producesData(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| tc.tool.producesData(),
            else => false,
        };
    }

    pub fn canHeal(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| tc.tool.canHeal(),
            else => false,
        };
    }

    pub fn needsLlm(self: Command) bool {
        return inline for (llm_tags) |tag| {
            if (self == tag) break true;
        } else false;
    }

    pub fn isRetryable(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| tc.tool.isRetryable(),
            else => false,
        };
    }

    pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!Command {
        return parseDiag(arena, line, null);
    }

    /// Same as `parse` but populates `diag` on `error.InvalidValue`.
    pub fn parseDiag(arena: std.mem.Allocator, line: []const u8, diag: ?*Schema.Diag) ParseError!Command {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return .{ .comment = {} };
        if (trimmed[0] == '#') return .{ .comment = {} };
        if (trimmed[0] != '/') return error.NotASlashCommand;

        const split = Schema.splitNameRest(trimmed[1..]) orelse return error.MissingName;

        inline for (llm_tags) |tag| {
            if (std.ascii.eqlIgnoreCase(split.name, @tagName(tag))) {
                if (split.rest.len > 0) return error.MalformedKv;
                return @unionInit(Command, @tagName(tag), {});
            }
        }

        const s = Schema.findByName(split.name) orelse return error.UnknownTool;
        const args = try s.parseValueDiag(arena, split.rest, diag);
        return .{ .tool_call = .{ .tool = s.tool, .args = args } };
    }

    /// Canonical recorder format. Round-trips with `parse`.
    pub fn format(self: Command, writer: *std.Io.Writer) (std.Io.Writer.Error || error{AmbiguousQuoting})!void {
        switch (self) {
            inline .login, .acceptCookies => |_, tag| try writer.writeAll("/" ++ @tagName(tag)),
            .comment => try writer.writeAll("#"),
            .tool_call => |tc| try tc.format(writer),
        }
    }

    /// `arguments` must outlive the returned Command. Callers that hand the
    /// Command to anything past the args' arena lifetime (e.g. heal, which
    /// reuses cmds after `RunToolsResult.deinit`) must deep-copy the arguments
    /// into their own arena before calling this.
    pub fn fromToolCall(tool: BrowserTool, arguments: ?std.json.Value) Command {
        return .{ .tool_call = .{ .tool = tool, .args = arguments } };
    }
};

const testing = @import("../testing.zig");

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
    try testing.expect((try Command.parse(arena.allocator(), "/acceptCookies")) == .acceptCookies);
}

test "parse: /goto positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/goto https://example.com");
    try testing.expect(cmd == .tool_call);
    try testing.expectString("goto", cmd.tool_call.name());
    try testing.expectString("https://example.com", cmd.tool_call.args.?.object.get("url").?.string);
}

test "parse: /click rejects positional (zero required fields)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.PositionalNotAllowed, Command.parse(arena.allocator(), "/click 'Login'"));
    const cmd = try Command.parse(arena.allocator(), "/click selector='Login'");
    try testing.expectString("Login", cmd.tool_call.args.?.object.get("selector").?.string);
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
    try testing.expectString("#agree", cmd.tool_call.args.?.object.get("selector").?.string);
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
    try testing.expectString("/goto 'https://example.com'", aw.written());
}

test "format: /click stays kv (zero required fields)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/click selector='Login'");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectString("/click selector='Login'", aw.written());
}

test "format: /eval emits triple-quote block for multi-line script" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const args = blk: {
        var obj: std.json.ObjectMap = .init(arena.allocator());
        try obj.put("script", .{ .string = "const x = 1;\nreturn x;" });
        break :blk std.json.Value{ .object = obj };
    };
    const cmd: Command = .{ .tool_call = .{ .tool = .eval, .args = args } };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try testing.expectString("/eval '''\nconst x = 1;\nreturn x;\n'''", aw.written());
}

test "format: /setChecked omits checked=true (default), keeps checked=false" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "/setChecked selector='#agree' checked=true", .expected = "/setChecked selector='#agree'" },
        .{ .input = "/setChecked selector='#x' checked=false", .expected = "/setChecked selector='#x' checked=false" },
    };
    for (cases) |case| {
        const cmd = try Command.parse(aa, case.input);
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.format(&aw.writer);
        try testing.expectString(case.expected, aw.written());
    }
}

test "format: /login and /acceptCookies" {
    var aw1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw1.deinit();
    try (Command{ .login = {} }).format(&aw1.writer);
    try testing.expectString("/login", aw1.written());

    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try (Command{ .acceptCookies = {} }).format(&aw2.writer);
    try testing.expectString("/acceptCookies", aw2.written());
}

test "canHeal: only page-local DOM commands are allowed" {
    // Table-driven over the live tool flags so adding a new tool can't
    // silently drift from the heal allow-list.
    const allow = [_]BrowserTool{ .click, .hover, .waitForSelector, .fill, .selectOption, .setChecked, .scroll, .extract, .press };
    const deny = [_]BrowserTool{ .goto, .eval, .tree, .markdown, .search, .links };

    for (allow) |action| {
        const cmd = Command.fromToolCall(action, null);
        try testing.expect(cmd.canHeal());
    }
    for (deny) |action| {
        const cmd = Command.fromToolCall(action, null);
        try testing.expect(!cmd.canHeal());
    }

    try testing.expect(!(Command{ .login = {} }).canHeal());
    try testing.expect(!(Command{ .acceptCookies = {} }).canHeal());
    try testing.expect(!(Command{ .comment = {} }).canHeal());
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

test "isRecorded: args shape and locator semantics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Null args: recorded iff the tool has zero required fields AND doesn't
    // need a locator. `/click` with null args is unreplayable — no selector,
    // no backendNodeId — even though click's schema has zero required fields.
    try testing.expect(!Command.fromToolCall(.click, null).isRecorded());
    try testing.expect(!Command.fromToolCall(.hover, null).isRecorded());
    try testing.expect(!Command.fromToolCall(.goto, null).isRecorded());
    try testing.expect(!Command.fromToolCall(.fill, null).isRecorded());

    // Non-object args: recorded iff the tool doesn't need a locator.
    try testing.expect(Command.fromToolCall(.goto, .{ .string = "https://x" }).isRecorded());
    try testing.expect(!Command.fromToolCall(.click, .{ .string = "#submit" }).isRecorded());

    // selector + backendNodeId: keep the call, drop the backendNodeId.
    {
        var obj: std.json.ObjectMap = .init(aa);
        try obj.put("selector", .{ .string = "#submit" });
        try obj.put("backendNodeId", .{ .integer = 42 });
        const cmd = Command.fromToolCall(.click, .{ .object = obj });
        try testing.expect(cmd.isRecorded());

        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.format(&aw.writer);
        try testing.expectString("/click selector='#submit'", aw.written());
    }

    // backendNodeId only: skipped — no replayable identifier.
    {
        var obj: std.json.ObjectMap = .init(aa);
        try obj.put("backendNodeId", .{ .integer = 42 });
        const cmd = Command.fromToolCall(.click, .{ .object = obj });
        try testing.expect(!cmd.isRecorded());
    }
}

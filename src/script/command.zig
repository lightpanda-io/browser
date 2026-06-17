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

//! A parsed slash command: a tool slash command, a `#`-comment, or an
//! `LlmCommand` trigger (`/login`, `/logout`, `/acceptCookies`). Multi-line
//! `'''…'''` blocks are assembled by the REPL before parse.

const std = @import("std");
const lp = @import("lightpanda");
const BrowserTool = lp.tools.Tool;
const Schema = @import("Schema.zig");

pub const ParseError = Schema.ParseError || error{
    NotASlashCommand,
};

const login_prompt =
    \\Find the login form on the current page. Fill in the credentials using
    \\$LP_* placeholders — the substitution happens inside the Lightpanda
    \\subprocess so the secret never enters your context. Do NOT call getEnv
    \\with a credential name (it would return the value).
    \\
    \\Call getEnv with NO `name` argument first to see which LP_* variables
    \\are set (names only, values never included). Then pick:
    \\- Site-prefixed form (LP_<SITE>_<FIELD>) when the list shows one for
    \\  the current site — e.g. $LP_HN_USERNAME for news.ycombinator.com,
    \\  $LP_GH_TOKEN for github.com.
    \\- Otherwise fall back to the unprefixed $LP_USERNAME / $LP_PASSWORD
    \\  (or $LP_EMAIL) form.
    \\
    \\Handle any cookie banners or popups first, then submit the form by
    \\clicking its submit button or pressing Enter in a filled field — there
    \\is no dedicated submit tool.
;

const logout_prompt =
    \\Log out of the current site. Find the logout control — often a link or
    \\button labeled "Log out", "Logout", or "Sign out", possibly inside an
    \\account or user menu you must open first — and click it. Handle any
    \\confirmation prompt, then verify the logged-out state (e.g. a login link
    \\reappears).
;

const accept_cookies_prompt =
    \\Find and dismiss the cookie consent banner on the current page.
    \\Look for "Accept", "Accept All", "I agree", or similar buttons and click them.
;

pub const Command = union(enum) {
    tool_call: ToolCall,
    llm: LlmCommand,
    comment: void,

    /// An LLM-driven command: `@tagName` is the wire-format slash name, and
    /// each value owns its `prompt()` (sent to the model) and `description()`
    /// (shown in `/help`) — mirroring how `tool_call` wraps `BrowserTool`.
    pub const LlmCommand = enum {
        login,
        logout,
        acceptCookies,

        pub fn prompt(self: LlmCommand) []const u8 {
            return switch (self) {
                .login => login_prompt,
                .logout => logout_prompt,
                .acceptCookies => accept_cookies_prompt,
            };
        }

        pub fn description(self: LlmCommand) []const u8 {
            return switch (self) {
                .login => "Log in using $LP_* credentials",
                .logout => "Log out of the current site",
                .acceptCookies => "Dismiss the cookie consent banner",
            };
        }
    };

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

            const positional = s.isBarePositional(args.object);

            var it = args.object.iterator();
            while (it.next()) |entry| {
                if (s.skipForFormat(entry.key_ptr.*, entry.value_ptr.*)) continue;
                if (entry.value_ptr.* != .string) continue;
                const is_body = positional and std.mem.eql(u8, entry.key_ptr.*, s.required[0]);
                if (!Schema.quotableInline(entry.value_ptr.string, is_body)) return false;
            }
            return true;
        }
    };

    pub fn isRecorded(self: Command) bool {
        return switch (self) {
            .comment => false,
            .llm => false,
            .tool_call => |tc| tc.isRecorded(),
        };
    }

    pub fn producesData(self: Command) bool {
        return switch (self) {
            .tool_call => |tc| tc.tool.producesData(),
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

        inline for (std.meta.fields(LlmCommand)) |f| {
            if (std.ascii.eqlIgnoreCase(split.name, f.name)) {
                if (split.rest.len > 0) return error.MalformedKv;
                return .{ .llm = @field(LlmCommand, f.name) };
            }
        }

        const s = Schema.findByName(split.name) orelse return error.UnknownTool;
        const args = try s.parseValueDiag(arena, split.rest, diag);
        return .{ .tool_call = .{ .tool = s.tool, .args = args } };
    }

    /// JavaScript recorder format for `lightpanda agent <script>.js`.
    /// Slash command parsing stays separate; this renders recorded browser
    /// primitives as blocking global function calls in the agent script
    /// runtime.
    pub fn formatJs(self: Command, arena: std.mem.Allocator, writer: *std.Io.Writer) (std.Io.Writer.Error || error{OutOfMemory})!void {
        switch (self) {
            .comment, .llm => return,
            .tool_call => |tc| try formatJsToolCall(tc, arena, writer),
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

fn formatJsToolCall(tc: Command.ToolCall, arena: std.mem.Allocator, writer: *std.Io.Writer) (std.Io.Writer.Error || error{OutOfMemory})!void {
    const s = tc.schema();
    // The bare call only; the recorder adds the `page.` receiver and any `await`.
    const args_val = tc.args orelse {
        try writer.print("{s}();", .{s.tool_name});
        return;
    };

    try writer.print("{s}(", .{s.tool_name});
    if (args_val == .object) {
        const args = args_val.object;
        const positional = s.isBarePositional(args);
        if (positional) {
            try writeJsFieldValue(arena, writer, tc.tool, s.required[0], args.get(s.required[0]).?);
        } else {
            try writeJsToolObject(arena, writer, tc.tool, s, args);
        }
    } else {
        try writeJsValue(arena, writer, args_val, .{});
    }
    try writer.writeAll(");");
}

fn writeJsToolObject(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    tool: BrowserTool,
    schema: *const Schema,
    args: std.json.ObjectMap,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    try writer.writeAll("{ ");
    var any = false;
    for (schema.fields) |f| {
        const v = args.get(f.name) orelse continue;
        if (tool == .extract and std.mem.eql(u8, f.name, "save")) continue;
        if (f.skipForFormat(v)) continue;
        if (any) try writer.writeAll(", ");
        any = true;
        try writeJsObjectKey(writer, f.name);
        try writer.writeAll(": ");
        try writeJsFieldValue(arena, writer, tool, f.name, v);
    }
    try writer.writeAll(" }");
}

fn writeJsFieldValue(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    tool: BrowserTool,
    field: []const u8,
    value: std.json.Value,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (tool == .extract and std.mem.eql(u8, field, "schema") and value == .string) {
        try writeExtractSchema(arena, writer, value.string);
        return;
    }
    const prefer_template = (tool == .evaluate and std.mem.eql(u8, field, "script")) or
        (tool == .waitForScript and std.mem.eql(u8, field, "script"));
    try writeJsValue(arena, writer, value, .{ .prefer_template = prefer_template });
}

const JsValueOpts = struct {
    prefer_template: bool = false,
};

fn writeJsValue(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
    opts: JsValueOpts,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |n| try writer.print("{d}", .{n}),
        .number_string => |s| try writer.writeAll(s),
        .string => |str| {
            if (opts.prefer_template and canUseTemplateLiteral(str)) {
                try writer.writeByte('`');
                try writer.writeAll(str);
                try writer.writeByte('`');
            } else {
                try writeJsonString(writer, str);
            }
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeJsValue(arena, writer, item, .{});
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeAll("{ ");
            var it = obj.iterator();
            var any = false;
            while (it.next()) |entry| {
                if (any) try writer.writeAll(", ");
                any = true;
                try writeJsObjectKey(writer, entry.key_ptr.*);
                try writer.writeAll(": ");
                try writeJsValue(arena, writer, entry.value_ptr.*, .{});
            }
            try writer.writeAll(" }");
        },
    }
}

fn writeExtractSchema(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema_src: []const u8,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_src, .{}) catch {
        return writeJsValue(arena, writer, .{ .string = schema_src }, .{ .prefer_template = std.mem.indexOfScalar(u8, schema_src, '\n') != null });
    };
    if (parsed == .object) {
        try writeJsValue(arena, writer, parsed, .{});
    } else {
        try writeJsValue(arena, writer, .{ .string = schema_src }, .{ .prefer_template = std.mem.indexOfScalar(u8, schema_src, '\n') != null });
    }
}

fn writeJsObjectKey(writer: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    if (isJsIdentifier(key)) {
        try writer.writeAll(key);
    } else {
        try writeJsonString(writer, key);
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    std.json.Stringify.value(value, .{}, writer) catch return error.WriteFailed;
}

fn canUseTemplateLiteral(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '\n') == null) return false;
    if (std.mem.indexOfScalar(u8, value, '`') != null) return false;
    if (std.mem.indexOf(u8, value, "${") != null) return false;
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, value, '\r') != null) return false;
    return true;
}

fn isJsIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_' and value[0] != '$') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return true;
}

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
    try testing.expectEqual(Command.LlmCommand.login, (try Command.parse(arena.allocator(), "/login")).llm);
    try testing.expectEqual(Command.LlmCommand.acceptCookies, (try Command.parse(arena.allocator(), "/acceptCookies")).llm);
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

test "parse: /getEnv positional binds to optional name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/getEnv LP_HN_USERNAME");
    try testing.expectString("getEnv", cmd.tool_call.name());
    try testing.expectString("LP_HN_USERNAME", cmd.tool_call.args.?.object.get("name").?.string);
    // No arg still lists names (null args).
    const list = try Command.parse(arena.allocator(), "/getEnv");
    try testing.expect(list.tool_call.args == null);
}

test "parse: /extract rejects positional after key=value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.PositionalMustComeFirst, Command.parse(arena.allocator(), "/extract save=front '{\"karma\":\"#karma\"}'"));
    const cmd = try Command.parse(arena.allocator(), "/extract '{\"karma\":\"#karma\"}' save=front");
    try testing.expectString("front", cmd.tool_call.args.?.object.get("save").?.string);
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

test "formatJs: positional and object arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "/goto https://example.com", .expected = "goto(\"https://example.com\");" },
        .{ .input = "/click selector='Login'", .expected = "click({ selector: \"Login\" });" },
        .{ .input = "/scroll y=200", .expected = "scroll({ y: 200 });" },
        .{ .input = "/setChecked selector='#x' checked=false", .expected = "setChecked({ selector: \"#x\", checked: false });" },
        // press records as object form, not bare `press("Enter")` (which would parse as a selector).
        .{ .input = "/press Enter", .expected = "press({ key: \"Enter\" });" },
    };
    for (cases) |case| {
        const cmd = try Command.parse(aa, case.input);
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString(case.expected, aw.written());
    }
}

test "formatJs: evaluate and extract strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        const cmd = try Command.parse(aa, "/evaluate '''\nconst x = 1;\nreturn x;\n'''");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("evaluate(`\nconst x = 1;\nreturn x;\n`);", aw.written());
    }
    {
        const cmd = try Command.parse(aa, "/evaluate 'return `tick` + ${x};'");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("evaluate(\"return `tick` + ${x};\");", aw.written());
    }
    {
        const cmd = try Command.parse(aa, "/extract '{\"title\":\"h1\",\"bad-key\":\".x\"}'");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("extract({ title: \"h1\", \"bad-key\": \".x\" });", aw.written());
    }
    {
        const cmd = try Command.parse(aa, "/extract '{\"title\":\"h1\"}' save=snap");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("extract({ schema: { title: \"h1\" } });", aw.written());
    }
}

test "isRecorded / producesData via tool flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const goto = try Command.parse(arena.allocator(), "/goto https://x");
    try testing.expect(goto.isRecorded());
    try testing.expect(!goto.producesData());

    const tree = try Command.parse(arena.allocator(), "/tree");
    try testing.expect(!tree.isRecorded());
    try testing.expect(tree.producesData());

    const login: Command = .{ .llm = .login };
    try testing.expect(!login.isRecorded());
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

    // selector + backendNodeId: still recorded (a usable selector is present).
    {
        var obj: std.json.ObjectMap = .init(aa);
        try obj.put("selector", .{ .string = "#submit" });
        try obj.put("backendNodeId", .{ .integer = 42 });
        const cmd = Command.fromToolCall(.click, .{ .object = obj });
        try testing.expect(cmd.isRecorded());
    }

    // backendNodeId only: skipped — no replayable identifier.
    {
        var obj: std.json.ObjectMap = .init(aa);
        try obj.put("backendNodeId", .{ .integer = 42 });
        const cmd = Command.fromToolCall(.click, .{ .object = obj });
        try testing.expect(!cmd.isRecorded());
    }
}

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

//! A parsed slash command: a tool call, a prompt-form tool command, a
//! `#`-comment, or an `LlmCommand` trigger (`/logout`). Multi-line `'''…'''`
//! blocks are assembled by the REPL before parse.

const std = @import("std");
const lp = @import("lightpanda");
const BrowserTool = lp.tools.Tool;
const Schema = @import("Schema.zig");

pub const ParseError = Schema.ParseError || error{
    NotASlashCommand,
};

const login_prompt_head =
    \\Sign in on the current page with the credentials below. Type each value
    \\exactly as written: they are $LP_* placeholders that the browser
    \\substitutes, so the secret never enters your context. Do NOT call getEnv
    \\with a credential name (it would return the value).
    \\
;

const login_prompt_tail =
    \\
    \\The login and acceptCookies tools need a TYPESAFE_API_KEY that is not
    \\set, so do this with fill, click and press. Handle any cookie banners or
    \\popups first, then submit the form by clicking its submit button or
    \\pressing Enter in a filled field.
;

const discover_login_prompt =
    \\Sign in on the current page using $LP_* placeholders: the browser
    \\substitutes them, so the secret never enters your context. Do NOT call
    \\getEnv with a credential name (it would return the value).
    \\
    \\Call getEnv with NO `name` argument first to see which LP_* variables
    \\are set (names only, values never included). Then pick:
    \\- Site-prefixed form (LP_<SITE>_<FIELD>) when the list shows one for
    \\  the current site — e.g. $LP_HN_USERNAME for news.ycombinator.com,
    \\  $LP_GH_TOKEN for github.com.
    \\- Otherwise fall back to the unprefixed $LP_USERNAME / $LP_PASSWORD
    \\  (or $LP_EMAIL) form.
    \\
++ login_prompt_tail;

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
    \\The acceptCookies tool needs a TYPESAFE_API_KEY that is not set, so click
    \\the button yourself.
;

/// The credentials the user gave, handed to the model as they were typed.
/// Null where a model must not take over: `decideOnly` promises nothing is
/// typed, and a literal password would put the secret in the model's context.
fn loginPrompt(arena: std.mem.Allocator, args: ?std.json.Value) error{OutOfMemory}!?[]const u8 {
    const fields = switch (args orelse return null) {
        .object => |object| object,
        else => return null,
    };
    if (fields.get("decideOnly")) |v| if (v == .bool and v.bool) return null;
    const password = placeholder(fields.get("password")) orelse return null;
    const username: ?[]const u8 = if (fields.get("username")) |v| switch (v) {
        .string => |name| name,
        else => return null,
    } else null;

    if (username) |user| {
        return try arena.print(login_prompt_head ++ "\nusername: {s}\npassword: {s}\n" ++ login_prompt_tail, .{ user, password });
    }
    return try arena.print(login_prompt_head ++ "\npassword: {s}\n(this page asks only for the password)\n" ++ login_prompt_tail, .{password});
}

const redacted = "[redacted]";

fn literalPassword(tc: Command.ToolCall) ?[]const u8 {
    if (tc.tool != .login) return null;
    const fields = switch (tc.args orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const value = fields.get("password") orelse return null;
    if (value != .string or value.string.len == 0 or placeholder(value) != null) return null;
    return value.string;
}

fn hasName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn placeholder(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    if (v != .string or !std.mem.startsWith(u8, v.string, "$LP_")) return null;
    return v.string;
}

pub const Command = union(enum) {
    tool_call: ToolCall,
    llm: LlmCommand,
    prompt: Prompt,
    comment: void,

    /// Leading text for a `takesPrompt` tool (`/click the sign in button`).
    pub const Prompt = struct {
        tool: BrowserTool,
        text: []const u8,
        /// Pinned key=value beside the prompt.
        args: ?std.json.Value,
    };

    /// An LLM-driven command: `@tagName` is the wire-format slash name, and
    /// each value owns its `prompt()` (sent to the model) and `description()`
    /// (shown in `/help`) — mirroring how `tool_call` wraps `BrowserTool`.
    pub const LlmCommand = enum {
        logout,

        pub fn prompt(self: LlmCommand) []const u8 {
            return switch (self) {
                .logout => logout_prompt,
            };
        }

        pub fn description(self: LlmCommand) []const u8 {
            return switch (self) {
                .logout => "Log out of the current site",
            };
        }
    };

    pub const ToolCall = struct {
        tool: BrowserTool,
        args: ?std.json.Value,

        pub fn name(self: ToolCall) [:0]const u8 {
            return @tagName(self.tool);
        }

        /// The command as the model may see it: a `login` password typed
        /// as-is rather than as a `$LP_*` placeholder is masked, in the line
        /// and in the args alike. The line is rebuilt from the masked args
        /// rather than searched: as typed, the password can be escaped
        /// (`"pa\\"ss"`) and no longer match its parsed value.
        pub fn forModel(self: ToolCall, arena: std.mem.Allocator, line: []const u8) error{OutOfMemory}!struct { line: []const u8, args: ?std.json.Value } {
            if (literalPassword(self) == null) return .{ .line = line, .args = self.args };
            var fields = try self.args.?.object.clone(arena);
            try fields.put(arena, "password", .{ .string = redacted });
            const args: std.json.Value = .{ .object = fields };
            return .{
                .line = try arena.print("/{s} {f}", .{ self.name(), std.json.fmt(args, .{}) }),
                .args = args,
            };
        }

        fn schema(self: ToolCall) *const Schema {
            return &Schema.all()[@backingInt(self.tool)];
        }

        /// Skip the line when the recorded form would not round-trip:
        /// - an arg the replay requires (`Tool.replayRequires`) is missing;
        /// - the only locator is the ephemeral `backendNodeId`;
        /// - a string field can't be quoted unambiguously.
        fn isRecorded(self: ToolCall) bool {
            if (!self.tool.isRecorded()) return false;
            const s = self.schema();
            const required = self.tool.replayRequires();
            const args = self.args orelse return s.required.len == 0 and required.len == 0;
            if (args != .object) return required.len == 0;

            if (!args.object.contains("selector") and args.object.contains("backendNodeId")) return false;
            for (required) |field| {
                if (!args.object.contains(field)) return false;
            }

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
            .comment, .llm, .prompt => false,
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

        inline for (@typeInfo(LlmCommand).@"enum".field_names) |field_name| {
            if (std.ascii.eqlIgnoreCase(split.name, field_name)) {
                if (split.rest.len > 0) return error.MalformedKv;
                return .{ .llm = @field(LlmCommand, field_name) };
            }
        }

        const s = Schema.findByName(split.name) orelse return error.UnknownTool;
        if (s.tool == .login and split.rest.len == 0) {
            return .{ .tool_call = .{ .tool = .login, .args = null } };
        }
        if (Schema.takesPrompt(s.tool)) {
            if (try s.parsePrompt(arena, split.rest, diag)) |p| {
                return .{ .prompt = .{ .tool = s.tool, .text = p.prompt, .args = p.args } };
            }
        }
        const args = try s.parseValueDiag(arena, split.rest, diag);
        return .{ .tool_call = .{ .tool = s.tool, .args = args } };
    }

    /// JavaScript recorder format for `lightpanda run <script>.js`.
    /// Slash command parsing stays separate; this renders recorded browser
    /// primitives as blocking global function calls in the agent script
    /// runtime.
    pub fn formatJs(self: Command, arena: std.mem.Allocator, writer: *std.Io.Writer) (std.Io.Writer.Error || error{OutOfMemory})!void {
        switch (self) {
            .comment, .llm, .prompt => return,
            .tool_call => |tc| try formatJsToolCall(tc, arena, writer),
        }
    }

    /// How a model would drive a tool that asks Jev instead, for the REPL to
    /// fall back to when there is no TypeSafe key. Not `LlmCommand` values:
    /// the slash name has to reach the tool, and `parseDiag` resolves
    /// `LlmCommand` first.
    pub fn fallbackPrompt(arena: std.mem.Allocator, tc: ToolCall) error{OutOfMemory}!?[]const u8 {
        return switch (tc.tool) {
            .acceptCookies => accept_cookies_prompt,
            .login => loginPrompt(arena, tc.args),
            else => null,
        };
    }

    /// What bare `/login` stands for. `$LP_PASSWORD` is the documented
    /// convention, so it fills in without guessing; a site-prefixed name is
    /// never matched to the host, since a wrong match sends one site's
    /// password to another's form. Without the convention, a model can do
    /// that matching where there is no key, and the user names the variables
    /// where there is one.
    pub const BareLogin = union(enum) {
        args: std.json.Value,
        prompt: []const u8,
        usage: []const u8,
    };

    pub const bare_login_help =
        \\Bare /login uses $LP_PASSWORD with $LP_USERNAME (or $LP_EMAIL) when set.
        \\Otherwise, without 
    ++ @import("zenai").typesafe.env_var_name ++
        \\ the model picks the LP_* variables for the
        \\site; with it, pass password=$LP_… username=$LP_….
    ;

    pub fn bareLogin(arena: std.mem.Allocator, lp_names: []const []const u8, has_key: bool) error{OutOfMemory}!BareLogin {
        if (hasName(lp_names, "LP_PASSWORD")) {
            var fields: std.json.ObjectMap = .empty;
            try fields.put(arena, "password", .{ .string = "$LP_PASSWORD" });
            for ([_][]const u8{ "LP_USERNAME", "LP_EMAIL" }) |name| {
                if (hasName(lp_names, name)) {
                    try fields.put(arena, "username", .{ .string = try arena.print("${s}", .{name}) });
                    break;
                }
            }
            return .{ .args = .{ .object = fields } };
        }
        if (!has_key) return .{ .prompt = discover_login_prompt };
        if (lp_names.len == 0) {
            return .{ .usage = "/login: no LP_* variables are set; set LP_USERNAME and LP_PASSWORD, or pass password=$LP_… username=$LP_…" };
        }
        return .{ .usage = try arena.print("/login: LP_PASSWORD is not set; pass password=$LP_… username=$LP_… (set: {s})", .{
            try std.mem.join(arena, ", ", lp_names),
        }) };
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
    const json_source = (tool == .extract and std.mem.eql(u8, field, "schema")) or
        (tool == .classify and std.mem.eql(u8, field, "questions"));
    if (json_source and value == .string) {
        try writeJsonSource(arena, writer, value.string);
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

/// Anything that is not a JSON object or array stays a string literal.
fn writeJsonSource(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    source: []const u8,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch null;
    if (parsed) |value| switch (value) {
        .object, .array => return writeJsValue(arena, writer, value, .{}),
        else => {},
    };
    try writeJsValue(arena, writer, .{ .string = source }, .{ .prefer_template = std.mem.findScalar(u8, source, '\n') != null });
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
    if (std.mem.findScalar(u8, value, '\n') == null) return false;
    if (std.mem.findScalar(u8, value, '`') != null) return false;
    if (std.mem.find(u8, value, "${") != null) return false;
    if (std.mem.findScalar(u8, value, '\\') != null) return false;
    if (std.mem.findScalar(u8, value, '\r') != null) return false;
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

fn fallbackFor(arena: std.mem.Allocator, tool: BrowserTool, args: []const u8) !?[]const u8 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    return Command.fallbackPrompt(arena, .{ .tool = tool, .args = value });
}

test "fallbackPrompt: only the tools that ask Jev have a prompt form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Both prompts tell the model why the tool is out of reach, by the
    // variable's real name.
    const key = @import("zenai").typesafe.env_var_name;
    try testing.expect(std.mem.find(u8, (try fallbackFor(aa, .acceptCookies, "{}")).?, key) != null);
    const login = (try fallbackFor(aa, .login,
        \\{"password":"$LP_PASSWORD"}
    )).?;
    try testing.expect(std.mem.find(u8, login, key) != null);
    // `logout` is still an LlmCommand, so it never reaches here as a tool.
    try testing.expectEqual(null, try fallbackFor(aa, .tree, "{}"));
    try testing.expectEqual(null, try fallbackFor(aa, .classify, "{}"));
}

test "fallbackPrompt: the model is given the credentials the command was" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const both = (try fallbackFor(aa, .login,
        \\{"username":"$LP_HN_USERNAME","password":"$LP_HN_PASSWORD"}
    )).?;
    try testing.expect(std.mem.find(u8, both, "username: $LP_HN_USERNAME\n") != null);
    try testing.expect(std.mem.find(u8, both, "password: $LP_HN_PASSWORD\n") != null);

    const password_only = (try fallbackFor(aa, .login,
        \\{"password":"$LP_PIN"}
    )).?;
    try testing.expect(std.mem.find(u8, password_only, "username:") == null);
    try testing.expect(std.mem.find(u8, password_only, "password: $LP_PIN\n") != null);

    // A username is not a secret, so one typed as-is goes to the model as-is.
    const literal_user = (try fallbackFor(aa, .login,
        \\{"username":"ada","password":"$LP_PASSWORD"}
    )).?;
    try testing.expect(std.mem.find(u8, literal_user, "username: ada\n") != null);
}

test "fallbackPrompt: no model takes over where it would break a promise" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // decideOnly types nothing, and a model asked to sign in would.
    try testing.expectEqual(null, try fallbackFor(aa, .login,
        \\{"password":"$LP_PASSWORD","decideOnly":true}
    ));
    // A literal password would land in the model's context.
    try testing.expectEqual(null, try fallbackFor(aa, .login,
        \\{"password":"hunter2"}
    ));
}

test "parse: /logout is an LLM command, /login and /acceptCookies are tools" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try testing.expectEqual(Command.LlmCommand.logout, (try Command.parse(aa, "/logout")).llm);

    const cookies = try Command.parse(aa, "/acceptCookies");
    try testing.expectEqual(BrowserTool.acceptCookies, cookies.tool_call.tool);
    const login = try Command.parse(aa, "/login password=$LP_PASSWORD");
    try testing.expectEqual(BrowserTool.login, login.tool_call.tool);
    try testing.expectString("$LP_PASSWORD", login.tool_call.args.?.object.get("password").?.string);
}

test "parse: /goto positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try Command.parse(arena.allocator(), "/goto https://example.com");
    try testing.expect(cmd == .tool_call);
    try testing.expectString("goto", cmd.tool_call.name());
    try testing.expectString("https://example.com", cmd.tool_call.args.?.object.get("url").?.string);
}

test "parse: leading text on a prompt tool is a prompt, key=value stays literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const quoted = (try Command.parse(aa, "/click 'Login'")).prompt;
    try testing.expectEqual(BrowserTool.click, quoted.tool);
    try testing.expectString("'Login'", quoted.text);
    try testing.expect(quoted.args == null);

    try testing.expectString("the user's menu", (try Command.parse(aa, "/click the user's menu")).prompt.text);

    const fill = (try Command.parse(aa, "/fill the email field value=$LP_EMAIL")).prompt;
    try testing.expectString("the email field", fill.text);
    try testing.expectString("$LP_EMAIL", fill.args.?.object.get("value").?.string);
    try testing.expect(fill.args.?.object.get("selector") == null);

    try testing.expect((try Command.parse(aa, "/setChecked uncheck the newsletter box")).prompt.args == null);

    const extract = (try Command.parse(aa, "/extract all products with prices save=products")).prompt;
    try testing.expectString("all products with prices", extract.text);
    try testing.expectString("products", extract.args.?.object.get("save").?.string);

    const literal = try Command.parse(aa, "/click selector='Login'");
    try testing.expectString("Login", literal.tool_call.args.?.object.get("selector").?.string);
}

test "parse: tools without a prompt form keep their positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try testing.expectString("Enter", (try Command.parse(aa, "/press Enter")).tool_call.args.?.object.get("key").?.string);
    try testing.expectString("networkidle", (try Command.parse(aa, "/waitForState networkidle")).tool_call.args.?.object.get("state").?.string);
    try testing.expectString("#logout", (try Command.parse(aa, "/waitForSelector '#logout'")).tool_call.args.?.object.get("selector").?.string);
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

test "parse: positional must come before key=value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.PositionalMustComeFirst, Command.parse(arena.allocator(), "/goto timeout=5000 https://example.com"));
    try testing.expectError(error.PromptMustComeFirst, Command.parse(arena.allocator(), "/extract save=front '{\"karma\":\"#karma\"}'"));
    const cmd = try Command.parse(arena.allocator(), "/extract schema='{\"karma\":\"#karma\"}' save=front");
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
        const cmd = try Command.parse(aa, "/evaluate script='''\nconst x = 1;\nreturn x;\n'''");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("evaluate(`\nconst x = 1;\nreturn x;\n`);", aw.written());
    }
    {
        const cmd = try Command.parse(aa, "/evaluate script='return `tick` + ${x};'");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("evaluate(\"return `tick` + ${x};\");", aw.written());
    }
    {
        const cmd = try Command.parse(aa, "/extract schema='{\"title\":\"h1\",\"bad-key\":\".x\"}'");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("extract({ title: \"h1\", \"bad-key\": \".x\" });", aw.written());
    }
    {
        const cmd = try Command.parse(aa, "/extract schema='{\"title\":\"h1\"}' save=snap");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("extract({ schema: { title: \"h1\" } });", aw.written());
    }
}

test "formatJs: classify questions replay as literals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        const cmd = try Command.parse(aa, "/classify '{\"isBlocked\":true}'");
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("classify({ isBlocked: true });", aw.written());
    }
    {
        var questions: std.json.ObjectMap = .empty;
        try questions.put(aa, "isBlocked", .{ .bool = true });
        var args: std.json.ObjectMap = .empty;
        try args.put(aa, "questions", .{ .object = questions });
        try args.put(aa, "selector", .{ .string = "main" });
        const cmd = Command.fromToolCall(.classify, .{ .object = args });
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try cmd.formatJs(aa, &aw.writer);
        try testing.expectString("classify({ questions: { isBlocked: true }, selector: \"main\" });", aw.written());
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

    const logout: Command = .{ .llm = .logout };
    try testing.expect(!logout.isRecorded());

    const prompt = try Command.parse(arena.allocator(), "/click the sign in button");
    try testing.expect(!prompt.isRecorded());
}

test "isRecorded: screenshot needs a path to replay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expect(!Command.fromToolCall(.screenshot, null).isRecorded());

    var without: std.json.ObjectMap = .empty;
    try without.put(aa, "selector", .{ .string = "#main" });
    try testing.expect(!Command.fromToolCall(.screenshot, .{ .object = without }).isRecorded());

    var with: std.json.ObjectMap = .empty;
    try with.put(aa, "path", .{ .string = "shot.png" });
    try testing.expect(Command.fromToolCall(.screenshot, .{ .object = with }).isRecorded());
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
        var obj: std.json.ObjectMap = .empty;
        try obj.put(aa, "selector", .{ .string = "#submit" });
        try obj.put(aa, "backendNodeId", .{ .integer = 42 });
        const cmd = Command.fromToolCall(.click, .{ .object = obj });
        try testing.expect(cmd.isRecorded());
    }

    // backendNodeId only: skipped — no replayable identifier.
    {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(aa, "backendNodeId", .{ .integer = 42 });
        const cmd = Command.fromToolCall(.click, .{ .object = obj });
        try testing.expect(!cmd.isRecorded());
    }
}

test "bareLogin: the conventional names fill in, anything else is the user's call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const conventional = (try Command.bareLogin(aa, &.{ "LP_EMAIL", "LP_PASSWORD", "LP_USERNAME" }, true)).args.object;
    try testing.expectEqual("$LP_PASSWORD", conventional.get("password").?.string);
    try testing.expectEqual("$LP_USERNAME", conventional.get("username").?.string);

    const email = (try Command.bareLogin(aa, &.{ "LP_EMAIL", "LP_PASSWORD" }, true)).args.object;
    try testing.expectEqual("$LP_EMAIL", email.get("username").?.string);

    const password_only = (try Command.bareLogin(aa, &.{"LP_PASSWORD"}, false)).args.object;
    try testing.expectEqual(null, password_only.get("username"));

    const prefixed = &[_][]const u8{ "LP_HN_PASSWORD", "LP_HN_USERNAME" };
    const usage = (try Command.bareLogin(aa, prefixed, true)).usage;
    try testing.expect(std.mem.find(u8, usage, "LP_HN_PASSWORD, LP_HN_USERNAME") != null);
    try testing.expect(std.mem.find(u8, (try Command.bareLogin(aa, prefixed, false)).prompt, "getEnv with NO `name`") != null);
}

test "parse: bare /login is a login call with its arguments still to find" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tc = (try Command.parse(arena.allocator(), "/login")).tool_call;
    try testing.expectEqual(BrowserTool.login, tc.tool);
    try testing.expectEqual(null, tc.args);
}

test "forModel: a literal login password never reaches the model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const line = "/login username=ada password=hunter2";
    const literal = (try Command.parse(aa, line)).tool_call;
    const masked = try literal.forModel(aa, line);
    try testing.expectString("/login {\"username\":\"ada\",\"password\":\"[redacted]\"}", masked.line);
    try testing.expectString("[redacted]", masked.args.?.object.get("password").?.string);
    try testing.expectString("ada", masked.args.?.object.get("username").?.string);
    // The command itself still carries it, for the tool to type.
    try testing.expectString("hunter2", literal.args.?.object.get("password").?.string);

    // Typed escaped, it does not match its parsed value.
    const escaped_line =
        \\/login {"username":"ada","password":"pa\"ss"}
    ;
    const escaped = (try Command.parse(aa, escaped_line)).tool_call;
    try testing.expectString("pa\"ss", escaped.args.?.object.get("password").?.string);
    const escaped_masked = try escaped.forModel(aa, escaped_line);
    try testing.expect(std.mem.find(u8, escaped_masked.line, "ss\"") == null);
    try testing.expect(std.mem.find(u8, escaped_masked.line, "[redacted]") != null);

    const placeholder_line = "/login password=$LP_PASSWORD";
    const kept = try (try Command.parse(aa, placeholder_line)).tool_call.forModel(aa, placeholder_line);
    try testing.expectString(placeholder_line, kept.line);
}

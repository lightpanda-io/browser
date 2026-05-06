const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const SlashCommand = @import("SlashCommand.zig");
const c = @cImport({
    @cInclude("linenoise.h");
});

const Self = @This();

const ansi_reset = "\x1b[0m";
const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";
const ansi_cyan = "\x1b[36m";
const ansi_green = "\x1b[32m";
const ansi_red = "\x1b[31m";

history_path: ?[:0]const u8,

const CommandInfo = struct { name: [:0]const u8, hint: [:0]const u8 };

const commands = [_]CommandInfo{
    .{ .name = "GOTO", .hint = " <url>" },
    .{ .name = "CLICK", .hint = " '<selector>'" },
    .{ .name = "TYPE", .hint = " '<selector>' '<value>'" },
    .{ .name = "WAIT", .hint = " '<selector>'" },
    .{ .name = "SCROLL", .hint = " [x] [y]" },
    .{ .name = "HOVER", .hint = " '<selector>'" },
    .{ .name = "SELECT", .hint = " '<selector>' '<value>'" },
    .{ .name = "CHECK", .hint = " '<selector>' [true|false]" },
    .{ .name = "TREE", .hint = "" },
    .{ .name = "MARKDOWN", .hint = "" },
    .{ .name = "EXTRACT", .hint = " '<selector>'" },
    .{ .name = "EVAL", .hint = " '<script>'" },
    .{ .name = "LOGIN", .hint = "" },
    .{ .name = "ACCEPT_COOKIES", .hint = "" },
};

// Meta slash commands handled directly by the agent (not by ToolExecutor).
// Kept in sync with `handleSlash` in `Agent.zig`. Each slot is a pre-baked
// fragment like "[tool_name]" — meta args are positional (no `key=value`),
// so we can't reuse `SchemaInfo.hints` which assumes `[name=…]` syntax.
const MetaCommand = struct {
    name: [:0]const u8,
    hint_slots: []const []const u8,
};

const meta_slash_commands = [_]MetaCommand{
    .{ .name = "help", .hint_slots = &.{"[tool_name]"} },
    .{ .name = "quit", .hint_slots = &.{} },
};

// Slash command schemas, set by the agent after `SlashCommand.buildSchemas`.
// File-scope because the linenoise hint callback is a C function pointer with
// no user-data slot. Empty in non-REPL paths, which is harmless.
var slash_schemas: []const SlashCommand.SchemaInfo = &.{};

pub fn setSlashSchemas(schemas: []const SlashCommand.SchemaInfo) void {
    slash_schemas = schemas;
}

pub fn init(history_path: ?[:0]const u8) Self {
    c.linenoiseSetMultiLine(1);
    c.linenoiseSetCompletionCallback(&completionCallback);
    c.linenoiseSetHintsCallback(&hintsCallback);
    if (history_path) |path| {
        _ = c.linenoiseHistoryLoad(path.ptr);
    }
    return .{ .history_path = history_path };
}

const completion_buf_len = 256;

fn addSlashCompletion(lc: [*c]c.linenoiseCompletions, name_buf: *[completion_buf_len:0]u8, name: []const u8, partial: []const u8) void {
    const total = 1 + name.len;
    if (total >= name_buf.len) return;
    if (name.len < partial.len) return;
    if (!std.ascii.eqlIgnoreCase(name[0..partial.len], partial)) return;
    name_buf[0] = '/';
    @memcpy(name_buf[1..total], name);
    name_buf[total] = 0;
    c.linenoiseAddCompletion(lc, name_buf);
}

fn slashHint(name: []const u8, partial: []const u8) ?[]const u8 {
    if (name.len <= partial.len) return null;
    if (!std.ascii.eqlIgnoreCase(name[0..partial.len], partial)) return null;
    return name[partial.len..];
}

// Splits `/<name>[ <body>]`. Returns null when input doesn't start with `/`,
// has no name, or is just `/`. `body` is "" when the name is fully typed but
// no space has been entered yet.
fn parseSlashCommand(input: []const u8) ?struct { name: []const u8, body: []const u8 } {
    if (input.len < 2 or input[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, input, ' ')) |space| {
        if (space < 2) return null;
        return .{ .name = input[1..space], .body = input[space + 1 ..] };
    }
    return .{ .name = input[1..], .body = "" };
}

fn findSlashSchema(name: []const u8) ?*const SlashCommand.SchemaInfo {
    for (slash_schemas) |*s| {
        if (std.ascii.eqlIgnoreCase(s.tool_name, name)) return s;
    }
    return null;
}

fn findMetaSlots(name: []const u8) ?[]const []const u8 {
    for (meta_slash_commands) |meta| {
        if (std.ascii.eqlIgnoreCase(meta.name, name)) return meta.hint_slots;
    }
    return null;
}

// Writes one hint slot into `hint_buf` at `pos.*`. Adds a leading space unless
// this is the first slot AND the user input already ends in whitespace.
// Returns false if the slot doesn't fit (caller should bail).
fn writeHintSlot(
    pos: *usize,
    first_slot: *bool,
    buffer_ends_with_space: bool,
    open: []const u8,
    name: []const u8,
    close: []const u8,
) bool {
    const need_space = !first_slot.* or !buffer_ends_with_space;
    const space_len: usize = if (need_space) 1 else 0;
    const total = space_len + open.len + name.len + close.len;
    if (pos.* + total >= hint_buf.len) return false;
    if (need_space) {
        hint_buf[pos.*] = ' ';
        pos.* += 1;
    }
    @memcpy(hint_buf[pos.* .. pos.* + open.len], open);
    pos.* += open.len;
    @memcpy(hint_buf[pos.* .. pos.* + name.len], name);
    pos.* += name.len;
    @memcpy(hint_buf[pos.* .. pos.* + close.len], close);
    pos.* += close.len;
    first_slot.* = false;
    return true;
}

const BodyAnalysis = struct {
    used_buf: [16][]const u8 = undefined,
    used_len: usize = 0,
    // The trailing in-progress token when the user is typing a key prefix
    // (no `=` yet, not a positional binding). Null if the body is empty,
    // ends with whitespace, or the trailing token is fully committed.
    partial_key: ?[]const u8 = null,

    fn used(self: *const BodyAnalysis) []const []const u8 {
        return self.used_buf[0..self.used_len];
    }
};

// Walks `body` once and reports which field keys are already in use plus the
// partial key (if any) the user is currently typing. The leading token
// without `=` binds positionally to the single required field, mirroring
// the parser; that case never produces a partial_key.
fn analyzeBody(schema: *const SlashCommand.SchemaInfo, body: []const u8, buffer_ends_with_space: bool) BodyAnalysis {
    var a: BodyAnalysis = .{};

    var tokens_buf: [16][]const u8 = undefined;
    var tokens_len: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, &std.ascii.whitespace);
    while (it.next()) |tok| {
        if (tokens_len >= tokens_buf.len) break;
        tokens_buf[tokens_len] = tok;
        tokens_len += 1;
    }
    if (tokens_len == 0) return a;

    const last_idx = tokens_len - 1;
    for (tokens_buf[0..tokens_len], 0..) |tok, i| {
        const is_last_in_progress = i == last_idx and !buffer_ends_with_space;
        const is_first = i == 0;
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            if (a.used_len < a.used_buf.len) {
                a.used_buf[a.used_len] = tok[0..eq];
                a.used_len += 1;
            }
        } else if (is_first and schema.required.len == 1) {
            if (a.used_len < a.used_buf.len) {
                a.used_buf[a.used_len] = schema.required[0];
                a.used_len += 1;
            }
        } else if (is_last_in_progress) {
            a.partial_key = tok;
        }
    }
    return a;
}

// Render the per-argument hint for a browser-tool slash command. Three modes:
//   1. The trailing in-progress token is a key prefix → render the matching
//      field's name suffix + "=…" (e.g. `/click sel` → `ector=…`).
//   2. Otherwise → render `<required>` and `[optional=…]` for each unused field.
fn renderSchemaArgHint(
    schema: *const SlashCommand.SchemaInfo,
    body: []const u8,
    buffer_ends_with_space: bool,
) ?[*c]u8 {
    const a = analyzeBody(schema, body, buffer_ends_with_space);
    const used = a.used();

    if (a.partial_key) |pk| if (pk.len > 0) {
        for (schema.hints) |slot| {
            if (SlashCommand.containsName(used, slot.name)) continue;
            if (slot.name.len < pk.len) continue;
            if (!std.ascii.eqlIgnoreCase(slot.name[0..pk.len], pk)) continue;
            const suffix = slot.name[pk.len..];
            const trail = "=…";
            const total = suffix.len + trail.len;
            if (total >= hint_buf.len) return null;
            @memcpy(hint_buf[0..suffix.len], suffix);
            @memcpy(hint_buf[suffix.len .. suffix.len + trail.len], trail);
            hint_buf[total] = 0;
            return @ptrCast(&hint_buf);
        }
    };

    var pos: usize = 0;
    var first_slot = true;
    for (schema.hints) |slot| {
        if (SlashCommand.containsName(used, slot.name)) continue;
        const open: []const u8 = if (slot.required) "<" else "[";
        const close: []const u8 = if (slot.required) ">" else "=…]";
        if (!writeHintSlot(&pos, &first_slot, buffer_ends_with_space, open, slot.name, close)) return null;
    }

    if (pos == 0) return null;
    hint_buf[pos] = 0;
    return @ptrCast(&hint_buf);
}

// Meta-command variant: simple slot-index advance (meta has at most 1 slot).
fn renderMetaArgHint(slots: []const []const u8, body: []const u8, buffer_ends_with_space: bool) ?[*c]u8 {
    var committed: usize = 0;
    var in_token = false;
    for (body) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            in_token = false;
        } else {
            if (!in_token) committed += 1;
            in_token = true;
        }
    }
    if (committed >= slots.len) return null;

    var pos: usize = 0;
    for (slots[committed..], 0..) |slot, i| {
        const need_space = i > 0 or !buffer_ends_with_space;
        const space_len: usize = if (need_space) 1 else 0;
        if (pos + space_len + slot.len >= hint_buf.len) return null;
        if (need_space) {
            hint_buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(hint_buf[pos .. pos + slot.len], slot);
        pos += slot.len;
    }
    if (pos == 0) return null;
    hint_buf[pos] = 0;
    return @ptrCast(&hint_buf);
}

const help_arg_prefix = "/help ";

// Returns the partial argument when `input` matches `/help <partial>` with no
// trailing arguments (e.g. "/help g" → "g", "/help " → ""). Returns null when
// it doesn't apply (different command, or arg already terminated by a space).
fn parseHelpArgPrefix(input: []const u8) ?[]const u8 {
    if (input.len < help_arg_prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(input[0..help_arg_prefix.len], help_arg_prefix)) return null;
    var i = help_arg_prefix.len;
    while (i < input.len and input[i] == ' ') i += 1;
    const arg = input[i..];
    if (std.mem.indexOfScalar(u8, arg, ' ') != null) return null;
    return arg;
}

fn addHelpArgCompletion(lc: [*c]c.linenoiseCompletions, name_buf: *[completion_buf_len:0]u8, name: []const u8, partial: []const u8) void {
    const total = help_arg_prefix.len + name.len;
    if (total >= name_buf.len) return;
    if (name.len < partial.len) return;
    if (!std.ascii.eqlIgnoreCase(name[0..partial.len], partial)) return;
    @memcpy(name_buf[0..help_arg_prefix.len], help_arg_prefix);
    @memcpy(name_buf[help_arg_prefix.len..total], name);
    name_buf[total] = 0;
    c.linenoiseAddCompletion(lc, name_buf);
}

// Completes `/<known> [body...] <partial>` to `/<known> [body...] <field>=`
// for each unused field whose name has `partial` as a case-insensitive prefix.
// Skips when the user is in positional-argument mode (single-required schema,
// first token without `=`) — we can't usefully complete a value.
fn addPartialKeyCompletions(
    input: []const u8,
    body: []const u8,
    schema: *const SlashCommand.SchemaInfo,
    lc: [*c]c.linenoiseCompletions,
    name_buf: *[completion_buf_len:0]u8,
) void {
    const ends_ws = input[input.len - 1] == ' ';
    const a = analyzeBody(schema, body, ends_ws);
    // Without a partial AND without trailing whitespace, the user is mid-typing
    // a positional value or some other non-completable state — bail.
    if (a.partial_key == null and !ends_ws) return;

    const partial = a.partial_key orelse "";
    const prefix = input[0 .. input.len - partial.len];
    for (schema.hints) |slot| {
        if (SlashCommand.containsName(a.used(), slot.name)) continue;
        if (slot.name.len < partial.len) continue;
        if (!std.ascii.eqlIgnoreCase(slot.name[0..partial.len], partial)) continue;
        const total = prefix.len + slot.name.len + 1;
        if (total >= name_buf.len) continue;
        @memcpy(name_buf[0..prefix.len], prefix);
        @memcpy(name_buf[prefix.len .. prefix.len + slot.name.len], slot.name);
        name_buf[prefix.len + slot.name.len] = '=';
        name_buf[total] = 0;
        c.linenoiseAddCompletion(lc, name_buf);
    }
}

fn completionCallback(buf: [*c]const u8, lc: [*c]c.linenoiseCompletions) callconv(.c) void {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);

    // linenoise strdup's the string, so a stack buffer reused per match is
    // fine. 256 leaves room for partial-key completions where the prefix is
    // the whole input minus the trailing partial token.
    var name_buf: [completion_buf_len:0]u8 = undefined;

    const has_space = input.len > 0 and std.mem.indexOfScalar(u8, input, ' ') != null;

    if (parseHelpArgPrefix(input)) |partial| {
        for (browser_tools.tool_defs) |td| addHelpArgCompletion(lc, &name_buf, td.name, partial);
        for (meta_slash_commands) |meta| addHelpArgCompletion(lc, &name_buf, meta.name, partial);
    } else if (has_space and input[0] == '/') {
        if (parseSlashCommand(input)) |parts| {
            if (findSlashSchema(parts.name)) |schema| {
                addPartialKeyCompletions(input, parts.body, schema, lc, &name_buf);
            }
        }
    } else if (input.len > 0 and !has_space) {
        if (input[0] == '/') {
            const partial = input[1..];
            for (browser_tools.tool_defs) |td| addSlashCompletion(lc, &name_buf, td.name, partial);
            for (meta_slash_commands) |meta| addSlashCompletion(lc, &name_buf, meta.name, partial);
        } else {
            for (commands) |cmd| {
                if (cmd.name.len >= input.len and std.ascii.eqlIgnoreCase(cmd.name[0..input.len], input)) {
                    c.linenoiseAddCompletion(lc, cmd.name.ptr);
                }
            }
        }
    }

    // If we found nothing, register the input itself so linenoise enters
    // completion mode anyway. Otherwise it returns the Tab keypress to its
    // edit loop, which inserts '\t' into the buffer and corrupts the line.
    if (lc.*.len == 0) {
        c.linenoiseAddCompletion(lc, buf);
    }
}

// File-scope so the pointer survives the callback's stack frame; linenoise
// reads the returned hint in refreshShowHints() *after* this function has
// already returned, so a stack-local buffer would be UB.
var hint_buf: [64:0]u8 = undefined;

fn hintsCallback(buf: [*c]const u8, color: [*c]c_int, bold: [*c]c_int) callconv(.c) [*c]u8 {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
    if (input.len == 0) return null;

    color.* = 90;
    bold.* = 0;

    // /help <partial> — suggest a tool name (more useful than the slot hint
    // because we can show concrete completions).
    if (parseHelpArgPrefix(input)) |partial| {
        const suffix = blk: {
            for (browser_tools.tool_defs) |td| {
                if (slashHint(td.name, partial)) |s| break :blk s;
            }
            for (meta_slash_commands) |meta| {
                if (slashHint(meta.name, partial)) |s| break :blk s;
            }
            return null;
        };
        if (suffix.len + 1 > hint_buf.len) return null;
        @memcpy(hint_buf[0..suffix.len], suffix);
        hint_buf[suffix.len] = 0;
        return @ptrCast(&hint_buf);
    }

    // /<known-name>[ body] — render the remaining argument slots. Handles
    // both the exact-name case (body=="") and the in-progress-args case.
    if (parseSlashCommand(input)) |parts| {
        const ends_with_space = input[input.len - 1] == ' ';
        if (findSlashSchema(parts.name)) |schema| {
            return renderSchemaArgHint(schema, parts.body, ends_with_space) orelse null;
        }
        if (findMetaSlots(parts.name)) |slots| {
            return renderMetaArgHint(slots, parts.body, ends_with_space) orelse null;
        }
    }

    if (std.mem.indexOfScalar(u8, input, ' ') != null) return null;

    if (input[0] == '/') {
        const partial = input[1..];

        const suffix = blk: {
            for (browser_tools.tool_defs) |td| {
                if (slashHint(td.name, partial)) |s| break :blk s;
            }
            for (meta_slash_commands) |meta| {
                if (slashHint(meta.name, partial)) |s| break :blk s;
            }
            return null;
        };
        if (suffix.len + 1 > hint_buf.len) return null;
        @memcpy(hint_buf[0..suffix.len], suffix);
        hint_buf[suffix.len] = 0;
        return @ptrCast(&hint_buf);
    }

    for (commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(cmd.name, input)) {
            if (cmd.hint.len == 0) return null;
            return @ptrCast(@constCast(cmd.hint.ptr));
        }
        if (cmd.name.len > input.len and std.ascii.eqlIgnoreCase(cmd.name[0..input.len], input)) {
            return @ptrCast(@constCast(cmd.name.ptr + input.len));
        }
    }
    return null;
}

pub fn readLine(self: *Self, prompt: [*:0]const u8) ?[]const u8 {
    const line = c.linenoise(prompt) orelse return null;
    const slice = std.mem.sliceTo(line, 0);
    if (slice.len > 0) {
        _ = c.linenoiseHistoryAdd(line);
        if (self.history_path) |path| {
            _ = c.linenoiseHistorySave(path.ptr);
        }
    }
    return slice;
}

pub fn freeLine(_: *Self, line: []const u8) void {
    c.linenoiseFree(@ptrCast(@constCast(line.ptr)));
}

pub fn printAssistant(_: *Self, text: []const u8) void {
    const fd = std.posix.STDOUT_FILENO;
    _ = std.posix.write(fd, text) catch {};
    _ = std.posix.write(fd, "\n") catch {};
}

/// Print the result of an action command (GOTO, CLICK, ...) to stderr so
/// stdout stays reserved for data-producing commands.
pub fn printActionResult(_: *Self, text: []const u8) void {
    std.debug.print("{s}\n", .{text});
}

pub fn printToolCall(_: *Self, name: []const u8, args: []const u8) void {
    std.debug.print("\n{s}{s}[tool: {s}]{s} {s}\n", .{ ansi_dim, ansi_cyan, name, ansi_reset, args });
}

// 2000 keeps stderr readable while exposing the full window the LLM-judge
// actually consumes (SNAPSHOT_MAX_CHARS=900 in benchmarks/llm_judge.py); the
// 500 cap was the binding upstream limit and silently starved the judge of
// grounding evidence on tasks where the agent had observed the answer.
// Does NOT affect the agent's own LLM, which gets up to tool_output_max_bytes
// (1 MiB) via Agent.zig:capToolOutput.
const max_result_display_len = 2000;

pub fn printToolResult(_: *Self, name: []const u8, result: []const u8) void {
    const truncated = result[0..@min(result.len, max_result_display_len)];
    const ellipsis: []const u8 = if (result.len > max_result_display_len) "..." else "";
    std.debug.print("{s}{s}[result: {s}]{s} {s}{s}\n", .{ ansi_dim, ansi_green, name, ansi_reset, truncated, ellipsis });
}

pub fn printError(_: *Self, msg: []const u8) void {
    std.debug.print("{s}{s}Error: {s}{s}\n", .{ ansi_bold, ansi_red, msg, ansi_reset });
}

pub fn printErrorFmt(_: *Self, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}{s}Error: " ++ fmt ++ "{s}\n", .{ ansi_bold, ansi_red } ++ args ++ .{ansi_reset});
}

pub fn printInfo(_: *Self, msg: []const u8) void {
    std.debug.print("{s}{s}{s}\n", .{ ansi_dim, msg, ansi_reset });
}

pub fn printInfoFmt(_: *Self, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}" ++ fmt ++ "{s}\n", .{ansi_dim} ++ args ++ .{ansi_reset});
}

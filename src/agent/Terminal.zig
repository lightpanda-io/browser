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
// Kept in sync with `handleSlash` in `Agent.zig`. Meta args are positional
// (no `key=value`), so the slot strings are pre-bracketed and can't reuse
// `SchemaInfo.hints` which renders `[name=…]`.
const MetaCommand = struct {
    name: [:0]const u8,
    hint_slots: []const []const u8,
};

const meta_slash_commands = [_]MetaCommand{
    .{ .name = "help", .hint_slots = &.{"[tool_name]"} },
    .{ .name = "quit", .hint_slots = &.{} },
};

// Flat name list for the "match any slash command" search/completion paths.
const all_slash_names: [browser_tools.tool_defs.len + meta_slash_commands.len][]const u8 = blk: {
    var names: [browser_tools.tool_defs.len + meta_slash_commands.len][]const u8 = undefined;
    for (browser_tools.tool_defs, 0..) |td, i| names[i] = td.name;
    for (meta_slash_commands, 0..) |m, i| names[browser_tools.tool_defs.len + i] = m.name;
    break :blk names;
};

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

fn addPrefixedCompletion(
    lc: [*c]c.linenoiseCompletions,
    name_buf: *[completion_buf_len:0]u8,
    prefix: []const u8,
    name: []const u8,
    suffix: []const u8,
    partial: []const u8,
) void {
    if (!std.ascii.startsWithIgnoreCase(name, partial)) return;
    _ = std.fmt.bufPrintZ(name_buf, "{s}{s}{s}", .{ prefix, name, suffix }) catch return;
    c.linenoiseAddCompletion(lc, name_buf);
}

fn slashHint(name: []const u8, partial: []const u8) ?[]const u8 {
    if (name.len <= partial.len) return null;
    if (!std.ascii.startsWithIgnoreCase(name, partial)) return null;
    return name[partial.len..];
}

// Writes the first matching name's suffix into `hint_buf` so the user sees
// `/cli` ghost-completed to `ck`. Searches tool names then meta names.
fn renderNameSuffixHint(partial: []const u8) [*c]u8 {
    for (all_slash_names) |name| {
        if (slashHint(name, partial)) |s| {
            _ = std.fmt.bufPrintZ(&hint_buf, "{s}", .{s}) catch return null;
            return @ptrCast(&hint_buf);
        }
    }
    return null;
}

fn parseSlashCommand(input: []const u8) ?SlashCommand.Split {
    if (input.len < 2 or input[0] != '/' or input[1] == ' ') return null;
    return SlashCommand.splitNameRest(input[1..]);
}

fn findMetaSlots(name: []const u8) ?[]const []const u8 {
    for (meta_slash_commands) |meta| {
        if (std.ascii.eqlIgnoreCase(meta.name, name)) return meta.hint_slots;
    }
    return null;
}

// Returns false if the slot doesn't fit (caller should bail). Leading space
// is suppressed only on the first slot when the user's input already ends
// in whitespace, so the hint joins naturally to what they've typed.
fn writeHintSlot(pos: *usize, buffer_ends_with_space: bool, slot: SlashCommand.HintSlot) bool {
    const lead: []const u8 = if (pos.* > 0 or !buffer_ends_with_space) " " else "";
    const written = (if (slot.required)
        std.fmt.bufPrint(hint_buf[pos.*..], "{s}<{s}>", .{ lead, slot.name })
    else
        std.fmt.bufPrint(hint_buf[pos.*..], "{s}[{s}=…]", .{ lead, slot.name })) catch return false;
    pos.* += written.len;
    return true;
}

const max_tracked_fields = 32;

const BodyAnalysis = struct {
    used_buf: [max_tracked_fields][]const u8 = undefined,
    used_len: usize = 0,
    // The trailing in-progress token when the user is typing a key prefix
    // (no `=` yet, not a positional binding). Null if the body is empty,
    // ends with whitespace, or the trailing token is fully committed.
    partial_key: ?[]const u8 = null,

    fn used(self: *const BodyAnalysis) []const []const u8 {
        return self.used_buf[0..self.used_len];
    }
};

// The leading token without `=` binds positionally to the single required
// field, mirroring the parser; that case never produces a partial_key.
fn analyzeBody(schema: *const SlashCommand.SchemaInfo, body: []const u8, buffer_ends_with_space: bool) BodyAnalysis {
    var a: BodyAnalysis = .{};

    var tokens_buf: [max_tracked_fields][]const u8 = undefined;
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

// Two modes:
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
            if (!std.ascii.startsWithIgnoreCase(slot.name, pk)) continue;
            _ = std.fmt.bufPrintZ(&hint_buf, "{s}=…", .{slot.name[pk.len..]}) catch return null;
            return @ptrCast(&hint_buf);
        }
    };

    var pos: usize = 0;
    for (schema.hints) |slot| {
        if (SlashCommand.containsName(used, slot.name)) continue;
        if (!writeHintSlot(&pos, buffer_ends_with_space, slot)) return null;
    }

    if (pos == 0) return null;
    hint_buf[pos] = 0;
    return @ptrCast(&hint_buf);
}

// Meta-command variant: positional slots, no `key=` form. Slot strings come
// pre-bracketed (e.g. "[tool_name]") and are written verbatim.
fn renderMetaArgHint(slots: []const []const u8, body: []const u8, buffer_ends_with_space: bool) ?[*c]u8 {
    var committed: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, &std.ascii.whitespace);
    while (it.next()) |_| committed += 1;
    if (committed >= slots.len) return null;

    var pos: usize = 0;
    for (slots[committed..]) |slot| {
        const lead: []const u8 = if (pos > 0 or !buffer_ends_with_space) " " else "";
        const written = std.fmt.bufPrint(hint_buf[pos..], "{s}{s}", .{ lead, slot }) catch return null;
        pos += written.len;
    }
    if (pos == 0) return null;
    hint_buf[pos] = 0;
    return @ptrCast(&hint_buf);
}

const help_arg_prefix = "/help ";

// Returns the trailing argument when `input` is `/help <arg>` with no
// further whitespace; null otherwise (e.g. `/help foo bar`).
fn parseHelpArgPrefix(input: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(input, help_arg_prefix)) return null;
    const arg = std.mem.trimLeft(u8, input[help_arg_prefix.len..], " ");
    if (std.mem.indexOfScalar(u8, arg, ' ') != null) return null;
    return arg;
}

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
        addPrefixedCompletion(lc, name_buf, prefix, slot.name, "=", partial);
    }
}

fn completionCallback(buf: [*c]const u8, lc: [*c]c.linenoiseCompletions) callconv(.c) void {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);

    // linenoise strdup's the string, so a stack buffer reused per match is
    // fine. 256 leaves room for partial-key completions where the prefix is
    // the whole input minus the trailing partial token.
    var name_buf: [completion_buf_len:0]u8 = undefined;

    // If nothing matches, register the input itself so linenoise still enters
    // completion mode. Otherwise it returns the Tab keypress to its edit loop,
    // which inserts '\t' into the buffer and corrupts the line.
    defer if (lc.*.len == 0) c.linenoiseAddCompletion(lc, buf);

    if (parseHelpArgPrefix(input)) |partial| {
        for (all_slash_names) |name| addPrefixedCompletion(lc, &name_buf, help_arg_prefix, name, "", partial);
        return;
    }

    if (input.len == 0) return;
    const has_space = std.mem.indexOfScalar(u8, input, ' ') != null;

    if (input[0] == '/') {
        if (has_space) {
            if (parseSlashCommand(input)) |parts| {
                if (SlashCommand.findSchema(slash_schemas, parts.name)) |schema| {
                    addPartialKeyCompletions(input, parts.rest, schema, lc, &name_buf);
                }
            }
            return;
        }
        const partial = input[1..];
        for (all_slash_names) |name| addPrefixedCompletion(lc, &name_buf, "/", name, "", partial);
        return;
    }

    if (has_space) return;
    for (commands) |cmd| {
        if (std.ascii.startsWithIgnoreCase(cmd.name, input)) {
            c.linenoiseAddCompletion(lc, cmd.name.ptr);
        }
    }
}

// File-scope so the pointer survives the callback's stack frame; linenoise
// reads the returned hint in refreshShowHints() *after* this function has
// already returned, so a stack-local buffer would be UB. Sized for multi-slot
// schema hints like `<sel> [timeout=…] [text=…] [waitFor=…]`.
var hint_buf: [completion_buf_len:0]u8 = undefined;

fn hintsCallback(buf: [*c]const u8, color: [*c]c_int, bold: [*c]c_int) callconv(.c) [*c]u8 {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
    if (input.len == 0) return null;

    color.* = 90;
    bold.* = 0;

    // /help <partial> — suggest a tool name (more useful than the slot hint
    // because we can show concrete completions).
    if (parseHelpArgPrefix(input)) |partial| {
        return renderNameSuffixHint(partial);
    }

    if (parseSlashCommand(input)) |parts| {
        const ends_with_space = input[input.len - 1] == ' ';
        if (SlashCommand.findSchema(slash_schemas, parts.name)) |schema| {
            return renderSchemaArgHint(schema, parts.rest, ends_with_space) orelse null;
        }
        if (findMetaSlots(parts.name)) |slots| {
            return renderMetaArgHint(slots, parts.rest, ends_with_space) orelse null;
        }
    }

    if (std.mem.indexOfScalar(u8, input, ' ') != null) return null;

    if (input[0] == '/') {
        return renderNameSuffixHint(input[1..]);
    }

    for (commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(cmd.name, input)) {
            if (cmd.hint.len == 0) return null;
            return @ptrCast(@constCast(cmd.hint.ptr));
        }
        if (cmd.name.len > input.len and std.ascii.startsWithIgnoreCase(cmd.name, input)) {
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

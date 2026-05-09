const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Config = lp.Config;
const SlashCommand = @import("SlashCommand.zig");
const Spinner = @import("Spinner.zig");
const c = @cImport({
    @cInclude("linenoise.h");
});

const Self = @This();

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const cyan = "\x1b[36m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
};

const Verbosity = Config.AgentVerbosity;

fn atLeast(level: Verbosity, min: Verbosity) bool {
    return @intFromEnum(level) >= @intFromEnum(min);
}

history_path: ?[:0]const u8,
verbosity: Verbosity,
/// Non-null in REPL mode. Doubles as scratch arena for the pretty-printer
/// (reset per `printToolResult`, so memory is bounded by the largest single
/// tool output). REPL forces tool calls/results visible regardless of
/// verbosity — the dial only gates non-interactive runs.
repl_arena: ?std.heap.ArenaAllocator,
stderr_is_tty: bool,
spinner: Spinner,

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

pub fn init(allocator: std.mem.Allocator, history_path: ?[:0]const u8, verbosity: Verbosity, is_repl: bool) Self {
    c.linenoiseSetMultiLine(1);
    c.linenoiseSetCompletionCallback(&completionCallback);
    c.linenoiseSetHintsCallback(&hintsCallback);
    if (history_path) |path| {
        _ = c.linenoiseHistoryLoad(path.ptr);
    }
    const stderr_is_tty = std.posix.isatty(std.posix.STDERR_FILENO);
    return .{
        .history_path = history_path,
        .verbosity = verbosity,
        .repl_arena = if (is_repl) std.heap.ArenaAllocator.init(allocator) else null,
        .stderr_is_tty = stderr_is_tty,
        .spinner = .init(is_repl, stderr_is_tty),
    };
}

fn isRepl(self: *const Self) bool {
    return self.repl_arena != null;
}

pub fn deinit(self: *Self) void {
    self.spinner.deinit();
    if (self.repl_arena) |*a| a.deinit();
}

// Shared between the spinner-emit path (writes to an arena buffer) and the
// non-spinner TTY path (writes to stderr via std.debug.print).
const bullet_line_fmt = "{s}●{s} {s}[tool: {s}]{s} {s}\n";

/// Called after the tool returns.
///
/// - Spinner mode (TTY REPL): the running label flashes red on failure
///   (handled by `markToolFailed`). At `medium`+, *also* commit a
///   `● [tool: …]` line above the spinner so the run leaves a trace.
/// - No spinner (non-TTY/non-REPL): print the same line directly,
///   gated on `medium`+. In non-TTY contexts ANSI is still emitted —
///   pipes that strip color see plain text via the bullet character.
pub fn agentToolDone(self: *Self, name: []const u8, args: []const u8, ok: bool) void {
    if (self.spinner.enabled) {
        if (!ok) self.spinner.markToolFailed();
        if (!atLeast(self.verbosity, .medium)) return;
        if (self.repl_arena) |*a| {
            defer _ = a.reset(.retain_capacity);
            const bytes = formatBulletLine(a.allocator(), name, args, ok) catch return;
            _ = self.spinner.emitAbove(bytes);
        }
        return;
    }
    if (!atLeast(self.verbosity, .medium)) return;
    if (self.stderr_is_tty) {
        const bullet_color = if (ok) ansi.green else ansi.red;
        std.debug.print(bullet_line_fmt, .{ bullet_color, ansi.reset, ansi.dim, name, ansi.reset, args });
    } else {
        std.debug.print(
            "{s}{s}[tool: {s}]{s} {s}\n",
            .{ ansi.dim, ansi.cyan, name, ansi.reset, args },
        );
    }
}

fn formatBulletLine(arena: std.mem.Allocator, name: []const u8, args: []const u8, ok: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const bullet_color = if (ok) ansi.green else ansi.red;
    try w.print(bullet_line_fmt, .{ bullet_color, ansi.reset, ansi.dim, name, ansi.reset, args });
    return aw.written();
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
    // Reject `/ foo` (bare slash with arg) — `splitNameRest` would otherwise
    // accept "foo" as the name after trimming.
    if (input.len < 2 or input[0] != '/' or std.ascii.isWhitespace(input[1])) return null;
    return SlashCommand.splitNameRest(input[1..]);
}

fn findMetaSlots(name: []const u8) ?[]const []const u8 {
    for (meta_slash_commands) |meta| {
        if (std.ascii.eqlIgnoreCase(meta.name, name)) return meta.hint_slots;
    }
    return null;
}

// Appends `lead + formatted` to `hint_buf` at `pos`, advancing `pos`. Lead is
// a single space except on the very first slot when the user's input already
// ends in whitespace. Returns false if the buffer is full.
fn appendHint(pos: *usize, ends_ws: bool, comptime fmt: []const u8, args: anytype) bool {
    const lead: []const u8 = if (pos.* > 0 or !ends_ws) " " else "";
    const written = std.fmt.bufPrint(hint_buf[pos.*..], "{s}" ++ fmt, .{lead} ++ args) catch return false;
    pos.* += written.len;
    return true;
}

// Cap on tokens we read out of the body. Real schemas and CLI inputs have far
// fewer fields than this; extra tokens are ignored.
const max_tokens = 32;

const BodyAnalysis = struct {
    used: [max_tokens][]const u8 = undefined,
    used_len: usize = 0,
    // Trailing in-progress token when the user is typing a key prefix (no `=`
    // yet, not a positional binding). Null when the body is empty, ends with
    // whitespace, or the trailing token is fully committed.
    partial_key: ?[]const u8 = null,

    fn markUsed(self: *BodyAnalysis, name: []const u8) void {
        if (self.used_len >= self.used.len) return;
        self.used[self.used_len] = name;
        self.used_len += 1;
    }

    fn isUsed(self: *const BodyAnalysis, name: []const u8) bool {
        for (self.used[0..self.used_len]) |u| {
            if (std.mem.eql(u8, u, name)) return true;
        }
        return false;
    }
};

fn analyzeBody(schema: *const SlashCommand.SchemaInfo, body: []const u8, ends_ws: bool) BodyAnalysis {
    var a: BodyAnalysis = .{};

    var tokens: [max_tokens][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, &std.ascii.whitespace);
    while (it.next()) |tok| {
        if (n >= tokens.len) break;
        tokens[n] = tok;
        n += 1;
    }
    if (n == 0) return a;

    const last = n - 1;
    for (tokens[0..n], 0..) |tok, i| {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            a.markUsed(tok[0..eq]);
            continue;
        }
        if (i == 0 and schema.required.len == 1) {
            a.markUsed(schema.required[0]);
            continue;
        }
        if (i == last and !ends_ws) a.partial_key = tok;
    }
    return a;
}

// Two modes:
//   1. Trailing in-progress key prefix → render the matching field's name
//      suffix + "=…" (e.g. `/click sel` → `ector=…`).
//   2. Otherwise → render `<required>` and `[optional=…]` for each unused field.
fn renderSchemaArgHint(
    schema: *const SlashCommand.SchemaInfo,
    body: []const u8,
    ends_ws: bool,
) ?[*c]u8 {
    const a = analyzeBody(schema, body, ends_ws);

    if (a.partial_key) |pk| {
        for (schema.hints) |slot| {
            if (a.isUsed(slot.name)) continue;
            if (!std.ascii.startsWithIgnoreCase(slot.name, pk)) continue;
            _ = std.fmt.bufPrintZ(&hint_buf, "{s}=…", .{slot.name[pk.len..]}) catch return null;
            return @ptrCast(&hint_buf);
        }
    }

    var pos: usize = 0;
    for (schema.hints) |slot| {
        if (a.isUsed(slot.name)) continue;
        const ok = if (slot.required)
            appendHint(&pos, ends_ws, "<{s}>", .{slot.name})
        else
            appendHint(&pos, ends_ws, "[{s}=…]", .{slot.name});
        if (!ok) return null;
    }

    if (pos == 0) return null;
    hint_buf[pos] = 0;
    return @ptrCast(&hint_buf);
}

// Meta-command variant: positional slots, no `key=` form. Slot strings come
// pre-bracketed (e.g. "[tool_name]") and are written verbatim.
fn renderMetaArgHint(slots: []const []const u8, body: []const u8, ends_ws: bool) ?[*c]u8 {
    var committed: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, &std.ascii.whitespace);
    while (it.next()) |_| committed += 1;
    if (committed >= slots.len) return null;

    var pos: usize = 0;
    for (slots[committed..]) |slot| {
        if (!appendHint(&pos, ends_ws, "{s}", .{slot})) return null;
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
        if (a.isUsed(slot.name)) continue;
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
        const ends_ws = input[input.len - 1] == ' ';
        if (SlashCommand.findSchema(slash_schemas, parts.name)) |schema| {
            return renderSchemaArgHint(schema, parts.rest, ends_ws) orelse null;
        }
        if (findMetaSlots(parts.name)) |slots| {
            return renderMetaArgHint(slots, parts.rest, ends_ws) orelse null;
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
/// stdout stays reserved for data-producing commands. User-driven, so
/// shown unconditionally in REPL; outside REPL gated on `medium+`.
pub fn printActionResult(self: *Self, text: []const u8) void {
    if (!self.isRepl() and !atLeast(self.verbosity, .medium)) return;
    std.debug.print("{s}\n", .{text});
}

// Must exceed the downstream LLM-judge's snapshot window so it has full
// grounding evidence. Does not cap the agent's own LLM, which gets up to
// tool_output_max_bytes (1 MiB) via Agent.zig:capToolOutput. Bypassed in
// REPL where the human can scroll.
const max_result_display_len = 2000;

pub fn printToolResult(self: *Self, name: []const u8, result: []const u8) void {
    if (!self.isRepl() and !atLeast(self.verbosity, .high)) return;
    if (self.repl_arena) |*a| {
        defer _ = a.reset(.retain_capacity);
        const bytes = formatReplResult(a.allocator(), name, result) catch return;
        if (self.spinner.emitAbove(bytes)) return;
        _ = std.posix.write(std.posix.STDERR_FILENO, bytes) catch {};
        return;
    }
    const truncated = result[0..@min(result.len, max_result_display_len)];
    const ellipsis: []const u8 = if (result.len > max_result_display_len) "..." else "";
    std.debug.print("{s}{s}[result: {s}]{s} {s}{s}\n", .{ ansi.dim, ansi.green, name, ansi.reset, truncated, ellipsis });
}

/// REPL output: header + body, pretty-print JSON if parseable, raw otherwise.
/// Builds the entire payload in the arena so callers can route it past the
/// spinner (`emitAbove`) without interleaving with frame writes.
fn formatReplResult(arena: std.mem.Allocator, name: []const u8, result: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    // Most tool results are plain text (markdown, URLs, action confirmations).
    // Skip the JSON parse + Value tree allocation unless the payload could
    // plausibly be JSON — `result` may be up to 1 MiB.
    const trimmed = std.mem.trimLeft(u8, result, " \t\r\n");
    const looks_json = trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[');
    const parsed: ?std.json.Value = if (looks_json)
        std.json.parseFromSliceLeaky(std.json.Value, arena, result, .{}) catch null
    else
        null;
    const sep: []const u8 = if (parsed != null) "\n" else " ";
    try w.print("{s}{s}[result: {s}]{s}{s}", .{ ansi.dim, ansi.green, name, ansi.reset, sep });
    if (parsed) |v| {
        std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, w) catch {
            try w.writeAll(result);
        };
    } else {
        try w.writeAll(result);
    }
    try w.writeByte('\n');
    return aw.written();
}

pub fn printError(self: *Self, msg: []const u8) void {
    self.printErrorFmt("{s}", .{msg});
}

pub fn printErrorFmt(_: *Self, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}{s}Error: " ++ fmt ++ "{s}\n", .{ ansi.bold, ansi.red } ++ args ++ .{ansi.reset});
}

pub fn printInfo(self: *Self, msg: []const u8) void {
    if (!self.isRepl() and !atLeast(self.verbosity, .medium)) return;
    std.debug.print("{s}{s}{s}\n", .{ ansi.dim, msg, ansi.reset });
}

pub fn printInfoFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (!self.isRepl() and !atLeast(self.verbosity, .medium)) return;
    std.debug.print("{s}" ++ fmt ++ "{s}\n", .{ansi.dim} ++ args ++ .{ansi.reset});
}

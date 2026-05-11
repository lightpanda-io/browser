const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Config = lp.Config;
const SlashCommand = @import("SlashCommand.zig");
const Spinner = @import("Spinner.zig");
const c = @cImport({
    @cInclude("isocline.h");
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
/// Schemas the completer uses to render `/slash` arg hints. Empty until
/// `setSlashSchemas` is called.
slash_schemas: []const SlashCommand.SchemaInfo = &.{},

const CommandInfo = struct { name: [:0]const u8 };

const commands = [_]CommandInfo{
    .{ .name = "GOTO" },
    .{ .name = "CLICK" },
    .{ .name = "TYPE" },
    .{ .name = "WAIT" },
    .{ .name = "SCROLL" },
    .{ .name = "HOVER" },
    .{ .name = "SELECT" },
    .{ .name = "CHECK" },
    .{ .name = "TREE" },
    .{ .name = "MARKDOWN" },
    .{ .name = "EXTRACT" },
    .{ .name = "EVAL" },
    .{ .name = "LOGIN" },
    .{ .name = "ACCEPT_COOKIES" },
};

// Meta slash commands handled directly by the agent (not by ToolExecutor).
// Kept in sync with `handleSlash` in `Agent.zig`. Only the names matter for
// completion; arg hints are not surfaced separately (the menu is enough).
const meta_slash_commands = [_][:0]const u8{ "help", "quit" };

// Flat name list for the "match any slash command" search/completion paths.
const all_slash_names: [browser_tools.tool_defs.len + meta_slash_commands.len][]const u8 = blk: {
    var names: [browser_tools.tool_defs.len + meta_slash_commands.len][]const u8 = undefined;
    for (browser_tools.tool_defs, 0..) |td, i| names[i] = td.name;
    for (meta_slash_commands, 0..) |m, i| names[browser_tools.tool_defs.len + i] = m;
    break :blk names;
};

/// Stores the schemas on the Terminal and (re-)registers isocline's
/// completer with `self` as user-data so the callback can reach them via
/// `ic_completion_arg`. Called from Agent.zig after the Terminal is in its
/// final memory location.
pub fn setSlashSchemas(self: *Self, schemas: []const SlashCommand.SchemaInfo) void {
    self.slash_schemas = schemas;
    c.ic_set_default_completer(&completionCallback, self);
}

pub fn init(allocator: std.mem.Allocator, history_path: ?[:0]const u8, verbosity: Verbosity, is_repl: bool) Self {
    _ = c.ic_enable_multiline(true);
    _ = c.ic_enable_hint(true);
    _ = c.ic_enable_inline_help(true);
    // Default is 400ms; match linenoise's instant ghost-suffix behavior so
    // users see the inline preview as they type without a noticeable pause.
    _ = c.ic_set_hint_delay(0);
    // Disable automatic brace/quote insertion — selectors quoted with ' or "
    // are common in PandaScript and auto-inserting closers gets in the user's
    // way more than it helps.
    _ = c.ic_enable_brace_insertion(false);
    // Clear isocline's default `> ` prompt marker so the prompt text we pass
    // to ic_readline renders verbatim; the agent already supplies its own
    // `> ` prefix.
    c.ic_set_prompt_marker("", "");
    // PandaScript syntax highlighting. Names are namespaced `ps-*` so users
    // (or a future theme system) can override via `ic_style_def` without
    // colliding with isocline's built-in `ic-*` styles. Bold/underline are
    // intentionally restrained — the prompt is meant to read, not glow.
    c.ic_style_def("ps-cmd", "ansi-cyan bold");
    c.ic_style_def("ps-slash", "ansi-magenta bold");
    c.ic_style_def("ps-string", "ansi-green");
    c.ic_style_def("ps-var", "ansi-yellow bold");
    c.ic_style_def("ps-url", "ansi-blue underline");
    c.ic_style_def("ps-key", "ansi-cyan");
    c.ic_style_def("ps-num", "ansi-yellow");
    c.ic_style_def("ps-err", "ansi-red");
    _ = c.ic_enable_highlight(true);
    c.ic_set_default_highlighter(&highlighterCallback, null);
    if (history_path) |path| {
        // -1 → default cap (200 entries). Passing a filename makes isocline
        // load existing entries and auto-persist additions.
        c.ic_set_history(path.ptr, -1);
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

// Bound on the largest single completion text we synthesize. The longest
// real case is a multi-slot schema hint glued onto a 64-char input.
const completion_buf_len = 512;

// Synthesizes a completion that, when accepted, replaces the user's entire
// current input (`input`) with `prefix ++ name ++ suffix`. The inline hint
// shown before Tab is just the trailing portion past `input.len`.
fn addPrefixedCompletion(
    cenv: ?*c.ic_completion_env_t,
    buf: *[completion_buf_len:0]u8,
    input: []const u8,
    prefix: []const u8,
    name: []const u8,
    suffix: []const u8,
    partial: []const u8,
) void {
    if (!std.ascii.startsWithIgnoreCase(name, partial)) return;
    const text = std.fmt.bufPrintZ(buf, "{s}{s}{s}", .{ prefix, name, suffix }) catch return;
    _ = c.ic_add_completion_prim(cenv, text.ptr, null, null, @intCast(input.len), 0);
}

fn parseSlashCommand(input: []const u8) ?SlashCommand.Split {
    // Reject `/ foo` (bare slash with arg) — `splitNameRest` would otherwise
    // accept "foo" as the name after trimming.
    if (input.len < 2 or input[0] != '/' or std.ascii.isWhitespace(input[1])) return null;
    return SlashCommand.splitNameRest(input[1..]);
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
    cenv: ?*c.ic_completion_env_t,
    input: []const u8,
    body: []const u8,
    schema: *const SlashCommand.SchemaInfo,
    buf: *[completion_buf_len:0]u8,
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
        addPrefixedCompletion(cenv, buf, input, prefix, slot.name, "=", partial);
    }
}

// Offers `$LP_*` completions when the user is mid-typing a `$VAR` token.
// Triggers wherever a `$` appears with only name characters following it, so
// it works in PandaScript args (`TYPE '#u' $LP_`), slash values
// (`/click value=$L`), and bare prefixes (`$L`). Names come from the same
// source as the `getEnv` tool — `std.os.environ` filtered to LP_*.
fn addEnvVarCompletions(
    cenv: ?*c.ic_completion_env_t,
    buf: *[completion_buf_len:0]u8,
    input: []const u8,
) void {
    const dollar = std.mem.lastIndexOfScalar(u8, input, '$') orelse return;
    const partial = input[dollar + 1 ..];
    for (partial) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return;
    }

    // Stack-only scratch for the env-name list. 16 KiB holds ~1000 names'
    // worth of pointer metadata (names themselves point into std.os.environ
    // and aren't copied) — far more than any realistic environment.
    var stack: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    const names = browser_tools.lpEnvNames(fba.allocator()) catch return;

    const head = input[0 .. dollar + 1];
    for (names) |name| {
        if (!std.ascii.startsWithIgnoreCase(name, partial)) continue;
        const text = std.fmt.bufPrintZ(buf, "{s}{s}", .{ head, name }) catch continue;
        _ = c.ic_add_completion_prim(cenv, text.ptr, null, null, @intCast(input.len), 0);
    }
}

fn completionCallback(cenv: ?*c.ic_completion_env_t, prefix: [*c]const u8) callconv(.c) void {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(prefix)), 0);
    const self_ptr = c.ic_completion_arg(cenv) orelse return;
    const self: *Self = @ptrCast(@alignCast(self_ptr));

    // Per-call scratch buffer for synthesized completion strings. Isocline
    // copies the string internally so reuse across candidates is fine.
    var buf: [completion_buf_len:0]u8 = undefined;

    // `/help <name>` — the arg is itself a tool name, not a value, so env-var
    // completion would be confusing here. Short-circuit.
    if (parseHelpArgPrefix(input)) |partial| {
        for (all_slash_names) |name| addPrefixedCompletion(cenv, &buf, input, help_arg_prefix, name, "", partial);
        return;
    }

    if (input.len == 0) return;
    const has_space = std.mem.indexOfScalar(u8, input, ' ') != null;

    if (input[0] == '/') {
        if (has_space) {
            if (parseSlashCommand(input)) |parts| {
                if (SlashCommand.findSchema(self.slash_schemas, parts.name)) |schema| {
                    addPartialKeyCompletions(cenv, input, parts.rest, schema, &buf);
                }
            }
            // Fall through so `value=$LP_` etc. picks up env completions.
        } else {
            const partial = input[1..];
            for (all_slash_names) |name| addPrefixedCompletion(cenv, &buf, input, "/", name, "", partial);
            return;
        }
    } else if (!has_space) {
        // Case-insensitive on the completion side so Tab also rewrites
        // mistyped lowercase (`goto` → `GOTO`). The highlighter stays
        // case-sensitive, so a lowercase-typed line reads as natural
        // language until the user accepts the completion.
        for (commands) |cmd| {
            if (std.ascii.startsWithIgnoreCase(cmd.name, input)) {
                const text = std.fmt.bufPrintZ(&buf, "{s}", .{cmd.name}) catch continue;
                _ = c.ic_add_completion_prim(cenv, text.ptr, null, null, @intCast(input.len), 0);
            }
        }
    }

    addEnvVarCompletions(cenv, &buf, input);
}

// PandaScript syntax highlighter. Invoked by isocline on every input change;
// keep it cheap. The `pos` and `count` passed to `ic_highlight` are byte
// offsets/lengths into `input`, not UTF-8 code points — fine here because we
// only tokenize on ASCII boundaries (whitespace, quotes, `=`, `$`).
fn highlighterCallback(henv: ?*c.ic_highlight_env_t, input: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const text = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input)), 0);
    if (text.len == 0) return;

    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i >= text.len) return;

    // First word: either `/slash` form or a bare PandaScript command name.
    // Unknown leading tokens get highlighted as errors so typos are visible
    // before the user hits Enter.
    const cmd_start = i;
    while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
    const cmd = text[cmd_start..i];
    if (cmd.len > 0 and cmd[0] == '/') {
        const name = cmd[1..];
        const style = if (isKnownSlashName(name)) "ps-slash" else "ps-err";
        c.ic_highlight(henv, @intCast(cmd_start), @intCast(cmd.len), style.ptr);
        highlightSlashArgs(henv, text, i);
    } else {
        // PandaScript commands are ALL CAPS. Known → keyword color. ALL CAPS
        // but unknown → red (likely typo). Anything else → no highlight,
        // it's a natural-language query for the LLM.
        const style: ?[*:0]const u8 = if (isKnownCommand(cmd))
            "ps-cmd"
        else if (isAllUpper(cmd))
            "ps-err"
        else
            null;
        if (style) |s| c.ic_highlight(henv, @intCast(cmd_start), @intCast(cmd.len), s);
        highlightPandaArgs(henv, text, i);
    }
}

fn isAllUpper(s: []const u8) bool {
    for (s) |ch| switch (ch) {
        'A'...'Z', '_', '0'...'9' => {},
        else => return false,
    };
    return s.len > 0;
}

fn isKnownCommand(name: []const u8) bool {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return true;
    }
    return false;
}

fn isKnownSlashName(name: []const u8) bool {
    for (all_slash_names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

// Color a non-quoted token based on its leading character: `$` → variable,
// `http(s)://` → URL, digits → number. Anything else falls through with no
// highlight (lets the terminal's default foreground show through).
fn highlightBareToken(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize, end: usize) void {
    if (start >= end) return;
    const tok = text[start..end];
    if (tok[0] == '$') {
        c.ic_highlight(henv, @intCast(start), @intCast(end - start), "ps-var".ptr);
        return;
    }
    if (std.mem.startsWith(u8, tok, "http://") or std.mem.startsWith(u8, tok, "https://")) {
        c.ic_highlight(henv, @intCast(start), @intCast(end - start), "ps-url".ptr);
        return;
    }
    if (std.ascii.isDigit(tok[0])) {
        var all_num = true;
        for (tok) |ch| if (!std.ascii.isDigit(ch) and ch != '.') {
            all_num = false;
            break;
        };
        if (all_num) c.ic_highlight(henv, @intCast(start), @intCast(end - start), "ps-num".ptr);
    }
}

// Consume a quoted token (single or double) at `start`, returning the index
// just past the closing quote. Handles backslash escapes minimally — enough
// not to confuse `\'` inside a single-quoted string.
fn scanQuoted(text: []const u8, start: usize) usize {
    if (start >= text.len) return start;
    const quote = text[start];
    var i = start + 1;
    while (i < text.len and text[i] != quote) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) i += 1;
    }
    return if (i < text.len) i + 1 else i;
}

fn highlightPandaArgs(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize) void {
    var i = start;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;

        if (text[i] == '\'' or text[i] == '"') {
            const tok_start = i;
            i = scanQuoted(text, i);
            c.ic_highlight(henv, @intCast(tok_start), @intCast(i - tok_start), "ps-string".ptr);
            continue;
        }
        const tok_start = i;
        while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
        highlightBareToken(henv, text, tok_start, i);
    }
}

fn highlightSlashArgs(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize) void {
    var i = start;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;

        const tok_start = i;
        while (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != '=') i += 1;
        const key_end = i;
        if (i < text.len and text[i] == '=') {
            c.ic_highlight(henv, @intCast(tok_start), @intCast(key_end - tok_start), "ps-key".ptr);
            i += 1; // consume '='
            const val_start = i;
            if (i < text.len and (text[i] == '\'' or text[i] == '"')) {
                i = scanQuoted(text, i);
                c.ic_highlight(henv, @intCast(val_start), @intCast(i - val_start), "ps-string".ptr);
            } else {
                while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
                highlightBareToken(henv, text, val_start, i);
            }
        }
        // bare positional (no `=`) — leave unstyled.
    }
}

pub fn readLine(_: *Self, prompt: [*:0]const u8) ?[]const u8 {
    // Isocline auto-adds the returned line to history and auto-persists when
    // a history file was set via `ic_set_history`.
    const line = c.ic_readline(prompt) orelse return null;
    return std.mem.sliceTo(line, 0);
}

pub fn freeLine(_: *Self, line: []const u8) void {
    c.ic_free(@ptrCast(@constCast(line.ptr)));
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
    self.printInfoFmt("{s}", .{msg});
}

pub fn printInfoFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (!self.isRepl() and !atLeast(self.verbosity, .medium)) return;
    std.debug.print("{s}" ++ fmt ++ "{s}\n", .{ansi.dim} ++ args ++ .{ansi.reset});
}

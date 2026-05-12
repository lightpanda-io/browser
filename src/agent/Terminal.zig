const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Config = lp.Config;
const Command = lp.script.Command;
const SlashCommand = @import("SlashCommand.zig");
const Spinner = @import("Spinner.zig");
const c = @cImport({
    @cInclude("isocline.h");
});

const Self = @This();

const style_cmd = "ps-cmd";
const style_slash = "ps-slash";
const style_string = "ps-string";
const style_var = "ps-var";
const style_url = "ps-url";
const style_key = "ps-key";
const style_num = "ps-num";
const style_err = "ps-err";

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const cyan = "\x1b[36m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const clear_eol = "\x1b[K";
};

const Verbosity = Config.AgentVerbosity;

fn atLeast(level: Verbosity, min: Verbosity) bool {
    return @intFromEnum(level) >= @intFromEnum(min);
}

allocator: std.mem.Allocator,
verbosity: Verbosity,
/// Non-null in REPL mode. Doubles as scratch arena for the pretty-printer
/// (reset per `printToolResult`, so memory is bounded by the largest single
/// tool output). REPL forces tool calls/results visible regardless of
/// verbosity — the dial only gates non-interactive runs.
repl_arena: ?std.heap.ArenaAllocator,
stderr_is_tty: bool,
spinner: Spinner,
slash_schemas: []const SlashCommand.SchemaInfo = &.{},

// Flat name list for the "match any slash command" search/completion paths.
const all_slash_names: [browser_tools.names.len + SlashCommand.meta_names.len][]const u8 = blk: {
    var arr: [browser_tools.names.len + SlashCommand.meta_names.len][]const u8 = undefined;
    for (browser_tools.names, 0..) |n, i| arr[i] = n;
    for (SlashCommand.meta_names, 0..) |m, i| arr[browser_tools.names.len + i] = m;
    break :blk arr;
};

/// Wires the isocline completer and hinter to `self` so the C callbacks can
/// reach `slash_schemas`. Must run after the Terminal is in its final memory
/// location.
pub fn attachCompleter(self: *Self, schemas: []const SlashCommand.SchemaInfo) void {
    self.slash_schemas = schemas;
    c.ic_set_default_completer(&completionCallback, self);
    c.ic_set_default_hinter(&hintsCallback, self);
}

pub fn init(allocator: std.mem.Allocator, history_path: ?[:0]const u8, verbosity: Verbosity, is_repl: bool) Self {
    _ = c.ic_enable_multiline(true);
    _ = c.ic_enable_hint(true);
    _ = c.ic_enable_inline_help(true);
    // Show ghost completions instantly; isocline's default is 400 ms.
    _ = c.ic_set_hint_delay(0);
    _ = c.ic_enable_brace_insertion(true);
    // `ps-*` namespace avoids colliding with isocline's built-in `ic-*` styles.
    c.ic_style_def(style_cmd, "ansi-cyan bold");
    c.ic_style_def(style_slash, "ansi-magenta bold");
    c.ic_style_def(style_string, "ansi-green");
    c.ic_style_def(style_var, "ansi-yellow bold");
    c.ic_style_def(style_url, "ansi-blue underline");
    c.ic_style_def(style_key, "ansi-cyan");
    c.ic_style_def(style_num, "ansi-yellow");
    c.ic_style_def(style_err, "ansi-red");
    c.ic_set_default_highlighter(&highlighterCallback, null);
    _ = c.ic_enable_highlight(true);
    if (history_path) |path| {
        c.ic_set_history(path.ptr, -1); // -1 → 200-entry default cap
    }
    const stderr_is_tty = std.posix.isatty(std.posix.STDERR_FILENO);
    return .{
        .allocator = allocator,
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
    if (self.spinner.enabled and !ok) self.spinner.markToolFailed();
    if (!atLeast(self.verbosity, .medium)) return;

    if (self.spinner.enabled) {
        const a = if (self.repl_arena) |*ra| ra else return;
        defer _ = a.reset(.retain_capacity);
        const bytes = formatBulletLine(a.allocator(), name, args, ok) catch return;
        _ = self.spinner.emitAbove(bytes);
        return;
    }
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

const completion_buf_len = 512;

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
        // Single-required schemas accept the first arg positionally
        // (`/goto https://example.com`); the schema's only required field
        // is implicitly bound.
        if (i == 0 and schema.required.len == 1) {
            a.markUsed(schema.required[0]);
            continue;
        }
        if (i == last and !ends_ws) a.partial_key = tok;
    }
    return a;
}

const help_arg_prefix = "/help ";

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
    std.debug.assert(input.len > 0);
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

// Completes `$LP_*` against the live process environment.
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

    // `lpEnvNames` caches the result process-wide, so calling per keystroke
    // costs one mutex acquire + pointer read after the first hit.
    const names = browser_tools.lpEnvNames() catch return;
    if (names.len == 0) return;

    const head = input[0 .. dollar + 1];
    for (names) |name| addPrefixedCompletion(cenv, buf, input, head, name, "", partial);
}

fn completionCallback(cenv: ?*c.ic_completion_env_t, prefix: [*c]const u8) callconv(.c) void {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(prefix)), 0);
    const self_ptr = c.ic_completion_arg(cenv) orelse return;
    const self: *Self = @ptrCast(@alignCast(self_ptr));

    var buf: [completion_buf_len:0]u8 = undefined;

    // `/help <name>`: arg is a tool name, not a value — skip env-var fallthrough.
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
            // Fall through so `value=$LP_` picks up env completions.
        } else {
            const partial = input[1..];
            // Trailing space on commands with params hands off to the hinter,
            // which renders the full ` <url> [timeout=…]` template uniformly
            // whether the user typed the name or Tab-completed it.
            for (all_slash_names) |name| {
                const suffix: []const u8 = if (slashHasParams(self.slash_schemas, name)) " " else "";
                addPrefixedCompletion(cenv, &buf, input, "/", name, suffix, partial);
            }
            return;
        }
    } else if (!has_space) {
        // Trailing space on argful keywords hands off to the hinter, which
        // renders ` '<selector>'` etc. uniformly whether typed or Tab-completed.
        // Case-insensitive Tab so `goto<TAB>` rewrites to `GOTO `; the
        // highlighter stays case-sensitive.
        for (Command.keywords) |kw| {
            const suffix: []const u8 = if (kw.params.len > 0) " " else "";
            addPrefixedCompletion(cenv, &buf, input, "", kw.name, suffix, input);
        }
    }

    addEnvVarCompletions(cenv, &buf, input);
}

// File-scope so the buffer outlives the callback's stack frame. Isocline's
// `sbuf_replace` copies the returned string into its own stringbuf, so it's
// safe to overwrite this on the next invocation. Single-threaded — isocline's
// edit loop runs on the main thread, and we have one Terminal instance.
var hint_buf: [completion_buf_len:0]u8 = undefined;

fn hintsCallback(input_c: [*c]const u8, arg: ?*anyopaque) callconv(.c) [*c]const u8 {
    const self_ptr = arg orelse return null;
    const self: *Self = @ptrCast(@alignCast(self_ptr));
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input_c)), 0);
    if (input.len == 0) return null;

    // `/help <partial>`: leave the inline hint to the completion-derived path.
    if (parseHelpArgPrefix(input)) |_| return null;

    if (parseSlashCommand(input)) |parts| {
        const ends_ws = input[input.len - 1] == ' ';
        if (SlashCommand.findSchema(self.slash_schemas, parts.name)) |schema| {
            return renderSchemaHint(schema, parts.rest, ends_ws);
        }
        return null;
    }

    if (input[0] == '/') return null;

    const space = std.mem.indexOfScalar(u8, input, ' ');
    const kw_end = space orelse input.len;
    const kw = exactKeywordMatch(input[0..kw_end]) orelse return null;
    if (kw.params.len == 0) return null;

    if (space == null) return writeHints(" ", kw.params);
    const body = input[kw_end + 1 ..];
    const cur = Command.analyzePandaBody(body);
    if (!cur.at_boundary or cur.complete_args >= kw.params.len) return null;
    const lead: []const u8 = if (input[input.len - 1] == ' ') "" else " ";
    return writeHints(lead, kw.params[cur.complete_args..]);
}

/// Join `fragments` into `hint_buf` with single-space separators, prefixed by
/// `lead` (typically `""` or `" "`). Null-terminates and returns the isocline
/// C pointer, or null when there's nothing to render or the buffer would
/// overflow. Shared by the slash and PandaScript hint renderers.
fn writeHints(lead: []const u8, fragments: []const []const u8) [*c]const u8 {
    if (fragments.len == 0) return null;
    const cap = hint_buf.len - 1;
    if (lead.len > cap) return null;
    @memcpy(hint_buf[0..lead.len], lead);
    var pos: usize = lead.len;
    for (fragments, 0..) |frag, i| {
        if (i > 0) {
            if (pos + 1 > cap) return null;
            hint_buf[pos] = ' ';
            pos += 1;
        }
        if (pos + frag.len > cap) return null;
        @memcpy(hint_buf[pos..][0..frag.len], frag);
        pos += frag.len;
    }
    hint_buf[pos] = 0;
    return @ptrCast(&hint_buf);
}

// Renders `<required>` and `[optional=…]` for each unused field, or
// `<keyname>=…` when the user is typing a key prefix.
fn renderSchemaHint(schema: *const SlashCommand.SchemaInfo, body: []const u8, ends_ws: bool) [*c]const u8 {
    const a = analyzeBody(schema, body, ends_ws);

    if (a.partial_key) |pk| {
        for (schema.hints) |slot| {
            if (a.isUsed(slot.name)) continue;
            if (!std.ascii.startsWithIgnoreCase(slot.name, pk)) continue;
            const text = std.fmt.bufPrintZ(&hint_buf, "{s}=…", .{slot.name[pk.len..]}) catch return null;
            return text.ptr;
        }
        return null;
    }

    var frags: [SlashCommand.max_hint_slots][]const u8 = undefined;
    var n: usize = 0;
    for (schema.hints) |slot| {
        if (a.isUsed(slot.name)) continue;
        frags[n] = slot.fragment;
        n += 1;
    }
    return writeHints(if (ends_ws) "" else " ", frags[0..n]);
}

// Advances `i` past whitespace; returns true if more text remains.
fn skipWs(text: []const u8, i: *usize) bool {
    while (i.* < text.len and std.ascii.isWhitespace(text[i.*])) i.* += 1;
    return i.* < text.len;
}

// Byte offsets to ic_highlight are not UTF-8 code points; safe because we
// only tokenize on ASCII boundaries (whitespace, quotes, `=`, `$`).
fn highlighterCallback(henv: ?*c.ic_highlight_env_t, input: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const text = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input)), 0);
    var i: usize = 0;
    if (!skipWs(text, &i)) return;

    const cmd_start = i;
    while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
    const cmd = text[cmd_start..i];
    // Commit to red once the user has moved past the token, OR as soon as the
    // prefix cannot complete to any known name.
    const closed = i < text.len;
    if (cmd.len > 0 and cmd[0] == '/') {
        c.ic_highlight(henv, @intCast(cmd_start), 1, style_slash.ptr);
        if (cmd.len > 1) {
            const name = cmd[1..];
            const style: ?[*:0]const u8 = if (isKnownSlashName(name))
                style_slash
            else if (closed or !slashHasPrefix(name))
                style_err
            else
                null;
            if (style) |s| c.ic_highlight(henv, @intCast(cmd_start + 1), @intCast(cmd.len - 1), s);
        }
        highlightSlashArgs(henv, text, i);
    } else {
        const style: ?[*:0]const u8 = blk: {
            if (isKnownCommand(cmd)) break :blk style_cmd;
            if (!looksLikeKeyword(cmd)) break :blk null;
            if (closed or !keywordHasPrefix(cmd)) break :blk style_err;
            break :blk null;
        };
        if (style) |s| c.ic_highlight(henv, @intCast(cmd_start), @intCast(cmd.len), s);
        highlightPandaArgs(henv, text, i);
    }
}

fn looksLikeKeyword(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch) and ch != '_') return false;
    }
    return true;
}

fn isKnownCommand(name: []const u8) bool {
    for (Command.keywords) |kw| {
        if (std.mem.eql(u8, kw.name, name)) return true;
    }
    return false;
}

fn exactKeywordMatch(input: []const u8) ?Command.KeywordSyntax {
    for (Command.keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(kw.name, input)) return kw;
    }
    return null;
}

fn isKnownSlashName(name: []const u8) bool {
    for (all_slash_names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

fn slashHasPrefix(name: []const u8) bool {
    for (all_slash_names) |n| {
        if (std.ascii.startsWithIgnoreCase(n, name)) return true;
    }
    return false;
}

fn keywordHasPrefix(name: []const u8) bool {
    for (Command.keywords) |kw| {
        if (std.mem.startsWith(u8, kw.name, name)) return true;
    }
    return false;
}

fn slashHasParams(schemas: []const SlashCommand.SchemaInfo, name: []const u8) bool {
    const s = SlashCommand.findSchema(schemas, name) orelse return false;
    return s.hints.len > 0;
}

fn highlightBareToken(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize, end: usize) void {
    if (start >= end) return;
    const tok = text[start..end];
    if (tok[0] == '$') {
        c.ic_highlight(henv, @intCast(start), @intCast(end - start), style_var.ptr);
        return;
    }
    if (lp.URL.isCompleteHTTPUrl(tok)) {
        c.ic_highlight(henv, @intCast(start), @intCast(end - start), style_url.ptr);
        return;
    }
    if (std.fmt.parseFloat(f64, tok)) |_| {
        c.ic_highlight(henv, @intCast(start), @intCast(end - start), style_num.ptr);
    } else |_| {}
}

// Returns the index just past the matching closing quote, or `text.len` if
// unterminated. Does not handle backslash escapes (matches SlashCommand.zig parser).
fn scanQuoted(text: []const u8, start: usize) usize {
    if (start >= text.len) return start;
    const close = std.mem.indexOfScalarPos(u8, text, start + 1, text[start]) orelse return text.len;
    return close + 1;
}

fn highlightPandaArgs(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize) void {
    var i = start;
    while (skipWs(text, &i)) {
        if (text[i] == '\'' or text[i] == '"') {
            const tok_start = i;
            i = scanQuoted(text, i);
            c.ic_highlight(henv, @intCast(tok_start), @intCast(i - tok_start), style_string.ptr);
            continue;
        }
        const tok_start = i;
        while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
        highlightBareToken(henv, text, tok_start, i);
    }
}

fn highlightSlashArgs(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize) void {
    var i = start;
    while (skipWs(text, &i)) {
        const tok_start = i;
        while (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != '=') i += 1;
        const key_end = i;
        if (i < text.len and text[i] == '=') {
            c.ic_highlight(henv, @intCast(tok_start), @intCast(key_end - tok_start), style_key.ptr);
            i += 1;
            const val_start = i;
            if (i < text.len and (text[i] == '\'' or text[i] == '"')) {
                i = scanQuoted(text, i);
                c.ic_highlight(henv, @intCast(val_start), @intCast(i - val_start), style_string.ptr);
            } else {
                while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
                highlightBareToken(henv, text, val_start, i);
            }
        }
    }
}

pub fn readLine(prompt: [*:0]const u8) ?[]const u8 {
    // Isocline auto-appends the line to its (optionally-persisted) history.
    const line = c.ic_readline(prompt) orelse return null;
    return std.mem.sliceTo(line, 0);
}

pub fn freeLine(line: []const u8) void {
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
        const bytes = formatReplResult(a.allocator(), result) catch return;
        if (self.spinner.emitAbove(bytes)) return;
        _ = std.posix.write(std.posix.STDERR_FILENO, bytes) catch {};
        return;
    }
    const truncated = result[0..@min(result.len, max_result_display_len)];
    const ellipsis: []const u8 = if (result.len > max_result_display_len) "..." else "";
    std.debug.print("{s}{s}[result: {s}]{s} {s}{s}\n", .{ ansi.dim, ansi.green, name, ansi.reset, truncated, ellipsis });
}

/// REPL output: green-dot marker followed by the body, pretty-printed if JSON.
/// Builds the entire payload in the arena so callers can route it past the
/// spinner (`emitAbove`) without interleaving with frame writes.
fn formatReplResult(arena: std.mem.Allocator, result: []const u8) ![]const u8 {
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
    try w.print("{s}●{s}{s}", .{ ansi.green, ansi.reset, sep });
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

pub fn printErrorFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (self.repl_arena) |*a| {
        defer _ = a.reset(.retain_capacity);
        var aw: std.Io.Writer.Allocating = .init(a.allocator());
        aw.writer.print("{s}●{s} " ++ fmt ++ "\n", .{ ansi.red, ansi.reset } ++ args) catch return;
        const bytes = aw.written();
        if (self.spinner.emitAbove(bytes)) return;
        _ = std.posix.write(std.posix.STDERR_FILENO, bytes) catch {};
        return;
    }
    std.debug.print("{s}{s}Error: " ++ fmt ++ "{s}\n", .{ ansi.bold, ansi.red } ++ args ++ .{ansi.reset});
}

pub fn printInfo(self: *Self, msg: []const u8) void {
    self.printInfoFmt("{s}", .{msg});
}

pub fn printInfoFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (!self.isRepl() and !atLeast(self.verbosity, .medium)) return;
    std.debug.print("{s}" ++ fmt ++ "{s}\n", .{ansi.dim} ++ args ++ .{ansi.reset});
}

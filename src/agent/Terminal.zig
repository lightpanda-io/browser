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

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Config = lp.Config;
const Command = lp.Command;
const Schema = lp.Schema;
const SlashCommand = @import("SlashCommand.zig");
const Spinner = @import("Spinner.zig");
const md_term = @import("md_term.zig");
const js_highlight = @import("js_highlight.zig");
const c = @cImport({
    @cInclude("isocline.h");
});

const Terminal = @This();

const style_slash = "ps-slash";
const style_string = "ps-string";
const style_var = "ps-var";
const style_url = "ps-url";
const style_key = "ps-key";
const style_num = "ps-num";
const style_err = "ps-err";
const style_jsmode = "ps-jsmode";
const style_keyword = "ps-keyword";
const style_comment = "ps-comment";
const style_jsglobal = "ps-jsglobal";
const style_fn = "ps-fn";
const style_method = "ps-method";
const style_type = "ps-type";

const ansi = @import("ansi.zig");

/// Command styling shared with the `/help` listing.
pub fn highlightCmd(comptime fragment: []const u8) []const u8 {
    return ansi.bold ++ ansi.teal ++ fragment ++ ansi.reset;
}

const Verbosity = Config.AgentVerbosity;

allocator: std.mem.Allocator,
verbosity: Verbosity,
/// Non-null in REPL mode. Doubles as pretty-printer scratch arena (reset per
/// `printToolOutcome`, so memory is bounded by the largest single tool output).
/// REPL forces tool calls/results visible regardless of verbosity — the dial
/// only gates non-interactive runs.
repl_arena: ?std.heap.ArenaAllocator,
stderr_is_tty: bool,
stdout_is_tty: bool,
spinner: Spinner,
completion_source: ?CompletionSource = null,
/// True while the REPL is in JS mode; set by isocline's mode callback.
js_mode: bool = false,
/// Per-mode history files (null outside REPL mode). `modeCallback` swaps the
/// active one so JS and normal recall stay separate.
history_paths: ?HistoryPaths = null,
/// Line-buffered markdown state for streamed assistant deltas; its `close`
/// resets everything so fence state can't leak into the next message. Only
/// used on the styled (REPL tty) path, hence the placeholder.
md_stream: md_term.Stream = .{ .show_table_placeholder = true },

/// Lets the completer/hinter pull dynamic candidates from the `Agent` without
/// `Terminal` depending on it (same idiom as `Session.cancel_hook`).
pub const CompletionSource = struct {
    context: *anyopaque,
    providers: *const fn (context: *anyopaque, arena: std.mem.Allocator) []const []const u8,
    /// May block on an HTTP fetch.
    models: *const fn (context: *anyopaque, arena: std.mem.Allocator) []const []const u8,
};

const llm_values = std.enums.values(Command.LlmCommand);
const all_slash_names: [browser_tools.names.len + SlashCommand.meta_commands.len + llm_values.len][]const u8 = blk: {
    var arr: [browser_tools.names.len + SlashCommand.meta_commands.len + llm_values.len][]const u8 = undefined;
    var idx: usize = 0;
    for (browser_tools.names) |n| {
        arr[idx] = n;
        idx += 1;
    }
    for (llm_values) |lc| {
        arr[idx] = @tagName(lc);
        idx += 1;
    }
    for (SlashCommand.meta_commands) |m| {
        arr[idx] = m.name;
        idx += 1;
    }
    break :blk arr;
};

/// Wires the isocline completer and hinter to `self` so the C callbacks can
/// reach the global schemas. Must run after the Terminal is in its final memory
/// location.
pub fn attachCompleter(self: *Terminal) void {
    c.ic_set_default_completer(&completionCallback, self);
    c.ic_set_default_hinter(&hintsCallback, self);
    c.ic_set_mode_callback(&modeCallback, self);
    c.ic_set_ctrl_d_hint("  press Ctrl-D again to exit");
    c.ic_set_esc_clear_hint("  esc again to clear");
    c.ic_set_mode_hint("  JS mode - esc to exit");
    c.ic_set_default_highlighter(&highlighterCallback, self);
}

fn modeCallback(active: bool, arg: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(arg orelse return));
    self.js_mode = active;
    if (self.history_paths) |hp| {
        c.ic_set_history((if (active) hp.js else hp.normal).ptr, -1);
    }
}

pub fn jsMode(self: *const Terminal) bool {
    return self.js_mode;
}

/// Separate history files for normal and JS prompt modes. isocline holds one
/// history list at a time, so we swap files on mode toggle rather than tag a
/// shared file.
pub const HistoryPaths = struct {
    normal: [:0]const u8,
    js: [:0]const u8,
};

pub fn init(allocator: std.mem.Allocator, history_paths: ?HistoryPaths, verbosity: Verbosity, is_repl: bool) Terminal {
    // Isocline probes the terminal on init (writes ESC[6n cursor-report on
    // stdout), so skip setup in script-only mode — `ic_readline` is never
    // reached there anyway.
    if (is_repl) {
        _ = c.ic_enable_multiline(true);
        _ = c.ic_enable_hint(true);
        _ = c.ic_enable_inline_help(true);
        // Show ghost completions instantly; isocline's default is 400 ms.
        _ = c.ic_set_hint_delay(0);
        _ = c.ic_enable_brace_insertion(true);
        // `ps-*` namespace avoids colliding with isocline's built-in `ic-*` styles.
        c.ic_style_def(style_slash, "ansi-teal bold");
        c.ic_style_def(style_string, "ansi-green");
        c.ic_style_def(style_var, "ansi-yellow");
        c.ic_style_def(style_url, "ansi-blue underline");
        c.ic_style_def(style_key, "ansi-blue");
        c.ic_style_def(style_num, "ansi-magenta");
        c.ic_style_def(style_err, "ansi-red");
        c.ic_style_def(style_jsmode, "ansi-red bold");
        c.ic_style_def(style_keyword, "ansi-blue bold");
        c.ic_style_def(style_comment, "ansi-darkgray italic");
        c.ic_style_def(style_jsglobal, "ansi-cyan");
        c.ic_style_def(style_fn, "ansi-teal");
        c.ic_style_def(style_method, "ansi-teal italic");
        c.ic_style_def(style_type, "ansi-cyan");
        // lighten the ghost/inline-hint color from isocline's default ansi-darkgray
        c.ic_style_def("ic-hint", "ansi-color=244");
        // `!` on an empty prompt toggles JS mode; state callback wired in attachCompleter.
        c.ic_set_prompt_mode("[" ++ style_jsmode ++ "]![/" ++ style_jsmode ++ "] ", '!');
        // Blank continuation marker so multiline input isn't prefixed with `>`.
        c.ic_set_prompt_marker("❯ ", "");
        _ = c.ic_enable_highlight(true);
        if (history_paths) |hp| {
            // Mode inactive at launch, so load the normal file; modeCallback
            // swaps to JS on mode entry.
            c.ic_set_history(hp.normal.ptr, -1); // -1 → 200-entry default cap
        }
    }
    const stderr_is_tty = std.posix.isatty(std.posix.STDERR_FILENO);
    return .{
        .allocator = allocator,
        .verbosity = verbosity,
        .repl_arena = if (is_repl) std.heap.ArenaAllocator.init(allocator) else null,
        .stderr_is_tty = stderr_is_tty,
        .stdout_is_tty = std.posix.isatty(std.posix.STDOUT_FILENO),
        .spinner = .init(is_repl, stderr_is_tty),
        .history_paths = history_paths,
    };
}

pub fn isRepl(self: *const Terminal) bool {
    return self.repl_arena != null;
}

pub fn deinit(self: *Terminal) void {
    self.spinner.deinit();
    if (self.repl_arena) |*a| a.deinit();
}

const bullet_line_fmt = "{s}●{s} {s}[tool: {s}]{s} {s}\n";

/// Mark the start of a manual REPL tool call. Pairs with `endTool`.
pub fn beginTool(self: *Terminal, name: []const u8, args: []const u8) void {
    self.spinner.setTool(name, args);
}

/// Mark the end of a manual REPL tool call. Clears the spinner; the caller's
/// `printToolOutcome` lays down the colored status dot.
pub fn endTool(self: *Terminal) void {
    self.spinner.cancel();
}

/// Called after the tool returns. At `medium`+, commits a `● [tool: …]` line
/// above the spinner (green/red bullet for ok/fail) so the run leaves a trace.
/// ANSI is emitted even in non-TTY contexts — pipes that strip color see plain
/// text via the bullet character.
pub fn agentToolDone(self: *Terminal, name: []const u8, args: []const u8, ok: bool) void {
    if (!self.verbosity.atLeast(.medium)) return;
    const spinner_on = self.spinner.isEnabled();

    if (spinner_on) {
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
            .{ ansi.dim, ansi.teal, name, ansi.reset, args },
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

// Cap on tokens read out of the body; extra tokens are ignored. Real schemas
// and CLI inputs have far fewer fields.
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

fn analyzeBody(schema: *const Schema, body: []const u8, ends_ws: bool) BodyAnalysis {
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
        // The first bare arg binds positionally to the schema's positional
        // field (`/goto https://example.com`, `/getEnv LP_TOKEN`).
        if (i == 0) if (schema.leadingPositionalField()) |pos| {
            a.markUsed(pos);
            continue;
        };
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

/// A field whose value the cursor is positioned to complete, plus the partial
/// value typed so far. Covers both the leading positional (`/waitForState net`)
/// and an explicit `key=` pair (`/waitForState state=net`).
const ValueAt = struct {
    field: Schema.FieldEntry,
    partial: []const u8,
    /// `key=value` form rather than the bare leading positional.
    kv: bool,
};

/// Classifies the token under the cursor as a value position for some schema
/// field. Null when the cursor isn't on a completable value (a key prefix, a
/// non-leading positional, or an unknown field).
fn valueAt(schema: *const Schema, body: []const u8, ends_ws: bool) ?ValueAt {
    var last: []const u8 = "";
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, &std.ascii.whitespace);
    while (it.next()) |tok| {
        last = tok;
        n += 1;
    }

    // An empty body or a trailing space puts the cursor on a fresh token after
    // the `n` committed ones; otherwise it sits on the last token.
    const active: []const u8 = if (ends_ws or n == 0) "" else last;
    const active_index: usize = if (ends_ws or n == 0) n else n - 1;

    if (std.mem.indexOfScalar(u8, active, '=')) |eq| {
        const field = schema.findField(active[0..eq]) orelse return null;
        return .{ .field = field, .partial = active[eq + 1 ..], .kv = true };
    }
    // The leading bare token binds to the schema's positional field (lone
    // required, or sole optional field like getEnv's `name`).
    if (active_index == 0) if (schema.leadingPositionalField()) |pos| {
        const field = schema.findField(pos) orelse return null;
        return .{ .field = field, .partial = active, .kv = false };
    };
    return null;
}

/// Returns true when it owns the completion, so the caller skips key hints.
fn addValueCompletions(
    cenv: ?*c.ic_completion_env_t,
    input: []const u8,
    body: []const u8,
    schema: *const Schema,
    buf: *[completion_buf_len:0]u8,
) bool {
    const ends_ws = input[input.len - 1] == ' ';
    const v = valueAt(schema, body, ends_ws) orelse return false;
    const prefix = input[0 .. input.len - v.partial.len];
    if (schema.tool == .getEnv) {
        var name_buf: [2048]u8 = undefined;
        const names = lpEnvNameList(&name_buf) orelse return true;
        for (names) |name| addPrefixedCompletion(cenv, buf, input, prefix, name, "", v.partial);
        return true;
    }
    if (v.field.enum_values.len == 0) return false;
    for (v.field.enum_values) |val| addPrefixedCompletion(cenv, buf, input, prefix, val, "", v.partial);
    return true;
}

fn addPartialKeyCompletions(
    cenv: ?*c.ic_completion_env_t,
    input: []const u8,
    body: []const u8,
    schema: *const Schema,
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

fn addMetaValueCompletions(
    self: *Terminal,
    cenv: ?*c.ic_completion_env_t,
    input: []const u8,
    body: []const u8,
    meta: *const SlashCommand.MetaCommand,
    buf: *[completion_buf_len:0]u8,
) void {
    // Past the first positional arg — don't offer value completions anymore.
    if (std.mem.indexOfAny(u8, body, &std.ascii.whitespace) != null) return;
    const prefix = input[0 .. input.len - body.len];

    if (meta.tag == .load or meta.tag == .save) {
        addPathCompletions(cenv, input, body, prefix, buf);
        return;
    }

    // `/provider` / `/model` candidates are resolved at runtime, not in `meta.values`.
    if (self.completion_source) |src| switch (meta.tag) {
        .provider, .model => {
            var name_buf: [512]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&name_buf);
            const names = if (meta.tag == .provider)
                src.providers(src.context, fba.allocator())
            else
                src.models(src.context, fba.allocator());
            for (names) |v| addPrefixedCompletion(cenv, buf, input, prefix, v, "", body);
            return;
        },
        else => {},
    };

    for (meta.values) |v| addPrefixedCompletion(cenv, buf, input, prefix, v, "", body);
}

/// Completes a path argument against the filesystem. The directory part of
/// the partial path is kept verbatim in each candidate; the trailing basename
/// is matched against directory entries, and directories get a `/` suffix.
fn addPathCompletions(
    cenv: ?*c.ic_completion_env_t,
    input: []const u8,
    body: []const u8,
    prefix: []const u8,
    buf: *[completion_buf_len:0]u8,
) void {
    const slash = std.mem.lastIndexOfScalar(u8, body, '/');
    const dir_part = if (slash) |i| body[0 .. i + 1] else "";
    const open_path = if (dir_part.len == 0) "." else dir_part;

    var dir = std.fs.cwd().openDir(open_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var name_buf: [completion_buf_len]u8 = undefined;
    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        const full = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ dir_part, entry.name }) catch continue;
        addPrefixedCompletion(cenv, buf, input, prefix, full, suffix, body);
    }
}

/// LP_* env var names (sorted) written into `buf`; null on enumeration failure.
/// Returned slices borrow `buf`, which must outlive them.
fn lpEnvNameList(buf: []u8) ?[]const []const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    return browser_tools.lpEnvNames(fba.allocator()) catch null;
}

/// Completes `$LP_*` against the live process environment.
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

    var name_buf: [2048]u8 = undefined;
    const names = lpEnvNameList(&name_buf) orelse return;
    if (names.len == 0) return;

    const head = input[0 .. dollar + 1];
    for (names) |name| addPrefixedCompletion(cenv, buf, input, head, name, "", partial);
}

fn completionCallback(cenv: ?*c.ic_completion_env_t, prefix: [*c]const u8) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(c.ic_completion_arg(cenv) orelse return));
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(prefix)), 0);

    var buf: [completion_buf_len:0]u8 = undefined;

    // `/help <name>`: arg is a command name, not a value — skip env-var fallthrough.
    if (parseHelpArgPrefix(input)) |partial| {
        for (all_slash_names) |name| addPrefixedCompletion(cenv, &buf, input, help_arg_prefix, name, "", partial);
        return;
    }

    if (input.len == 0) return;
    const has_space = std.mem.indexOfScalar(u8, input, ' ') != null;
    const inside_block = Schema.hasUnclosedTripleQuote(input);

    if (input[0] == '/') {
        if (!has_space) {
            const partial = input[1..];
            // Trailing space on commands with params hands off to the hinter,
            // which renders the full ` <url> [timeout=…]` template uniformly
            // whether the name was typed or Tab-completed.
            for (all_slash_names) |name| {
                const suffix: []const u8 = if (slashHasParams(name)) " " else "";
                addPrefixedCompletion(cenv, &buf, input, "/", name, suffix, partial);
            }
            return;
        } else if (!inside_block) {
            if (Schema.parseSlashCommand(input)) |parts| {
                if (Schema.findByName(parts.name)) |schema| {
                    if (!addValueCompletions(cenv, input, parts.rest, schema, &buf)) {
                        addPartialKeyCompletions(cenv, input, parts.rest, schema, &buf);
                    }
                } else if (SlashCommand.findMeta(parts.name)) |meta| {
                    self.addMetaValueCompletions(cenv, input, parts.rest, meta, &buf);
                }
            }
        }
        // Fall through so `value=$LP_` picks up env completions, including
        // inside an unclosed `'''` block.
    }

    addEnvVarCompletions(cenv, &buf, input);
}

// File-scope so the buffer outlives the callback's stack frame. Isocline's
// `sbuf_replace` copies the returned string into its own stringbuf, so
// overwriting this on the next invocation is safe. Single-threaded: isocline's
// edit loop runs on the main thread, and we have one Terminal instance.
var hint_buf: [completion_buf_len:0]u8 = undefined;

fn hintsCallback(input_c: [*c]const u8, arg: ?*anyopaque) callconv(.c) [*c]const u8 {
    const self: *Terminal = @ptrCast(@alignCast(arg orelse return null));
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input_c)), 0);

    // JS mode: the buffer is raw JS, so slash/kv hints don't apply.
    if (self.js_mode) return null;

    if (input.len == 0) return null;

    if (parseHelpArgPrefix(input)) |partial| return ghostFirstMatch(&all_slash_names, partial, "");

    // Inside an open `'''…'''` body the buffer is script text, not kv args.
    if (Schema.hasUnclosedTripleQuote(input)) return null;

    if (std.mem.eql(u8, input, "/")) return ghostFirstMatch(&all_slash_names, "", "");

    if (Schema.parseSlashCommand(input)) |parts| {
        const ends_ws = input[input.len - 1] == ' ';
        if (Schema.findByName(parts.name)) |schema| {
            return renderSchemaHint(schema, parts.rest, ends_ws);
        }
        if (SlashCommand.findMeta(parts.name)) |meta| {
            return self.renderMetaHint(meta, parts.rest, ends_ws);
        }
        if (std.mem.indexOfScalar(u8, input, ' ') == null) {
            return ghostFirstMatch(&all_slash_names, parts.name, "");
        }
        return null;
    }

    // Non-slash lines are natural-language prompts to the LLM (REPL only).
    // No syntactic hint to render — the LLM sees the line verbatim.
    return null;
}

/// Join `fragments` into `hint_buf` with single-space separators, prefixed by
/// `lead` (typically `""` or `" "`). Null-terminates and returns the isocline
/// C pointer, or null when nothing to render or the buffer would overflow.
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

/// Ghosts a meta command's argument: providers resolve synchronously, `/model`
/// needs a blocking fetch (placeholder until committed), static values match
/// `meta.values`.
fn renderMetaHint(self: *Terminal, meta: *const SlashCommand.MetaCommand, body: []const u8, ends_ws: bool) [*c]const u8 {
    if (meta.hint.len == 0) return null;
    if (ends_ws and body.len != 0) return null; // value already committed

    if (self.completion_source) |src| {
        var name_buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&name_buf);
        if (meta.tag == .provider) {
            const lead: []const u8 = if (body.len == 0 and !ends_ws) " " else "";
            return ghostFirstMatch(src.providers(src.context, fba.allocator()), body, lead);
        }
        if (meta.tag == .model and (ends_ws or body.len != 0)) {
            return ghostFirstMatch(src.models(src.context, fba.allocator()), body, "");
        }
    }

    if (body.len == 0) {
        var frags: [1][]const u8 = .{meta.hint};
        return writeHints(if (ends_ws) "" else " ", &frags);
    }
    if (ends_ws) return null;
    if (meta.tag == .load or meta.tag == .save) return ghostPathFirstMatch(body);
    return ghostFirstMatch(meta.values, body, "");
}

/// Ghosts the first filesystem entry that completes the partial path `body`,
/// appending `/` when the match is a directory.
fn ghostPathFirstMatch(body: []const u8) [*c]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, body, '/');
    const dir_part = if (slash) |i| body[0 .. i + 1] else "";
    const base = body[dir_part.len..];
    const open_path = if (dir_part.len == 0) "." else dir_part;

    var dir = std.fs.cwd().openDir(open_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch return null) |entry| {
        if (!std.ascii.startsWithIgnoreCase(entry.name, base)) continue;
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        const text = std.fmt.bufPrintZ(&hint_buf, "{s}{s}", .{ entry.name[base.len..], suffix }) catch return null;
        return text.ptr;
    }
    return null;
}

/// Ghosts `lead` + the suffix of the first `names` entry that prefix-matches
/// `body`.
fn ghostFirstMatch(names: []const []const u8, body: []const u8, lead: []const u8) [*c]const u8 {
    for (names) |v| {
        if (!std.ascii.startsWithIgnoreCase(v, body)) continue;
        const text = std.fmt.bufPrintZ(&hint_buf, "{s}{s}", .{ lead, v[body.len..] }) catch return null;
        return text.ptr;
    }
    return null;
}

/// Renders `<required>` and `[optional=…]` for each unused field, or
/// `<keyname>=…` when the user is typing a key prefix.
fn renderSchemaHint(schema: *const Schema, body: []const u8, ends_ws: bool) [*c]const u8 {
    // Ghost a matching enum value once the user is typing one. A bare leading
    // positional with nothing typed keeps the `<state> …` template below — more
    // informative than ghosting one arbitrary value.
    if (valueAt(schema, body, ends_ws)) |v| {
        if (v.field.enum_values.len > 0 and (v.kv or v.partial.len > 0)) {
            return ghostFirstMatch(v.field.enum_values, v.partial, "");
        }
        // getEnv's `name` ghosts a live LP_* var, like /provider ghosts a provider.
        if (schema.tool == .getEnv) {
            var name_buf: [2048]u8 = undefined;
            if (lpEnvNameList(&name_buf)) |names| {
                const lead: []const u8 = if (v.partial.len == 0 and !ends_ws) " " else "";
                if (ghostFirstMatch(names, v.partial, lead)) |hint| return hint;
            }
        }
    }

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

    var frags: [Schema.max_hint_slots][]const u8 = undefined;
    var n: usize = 0;
    for (schema.hints) |slot| {
        if (a.isUsed(slot.name)) continue;
        frags[n] = slot.fragment;
        n += 1;
    }
    return writeHints(if (ends_ws) "" else " ", frags[0..n]);
}

/// Index of the next non-whitespace byte at or after `start`, or null if only
/// whitespace remains.
fn skipWhitespace(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return if (i < text.len) i else null;
}

/// Byte offsets to ic_highlight are not UTF-8 code points; safe because we
/// only tokenize on ASCII boundaries (whitespace, quotes, `=`, `$`).
fn highlighterCallback(henv: ?*c.ic_highlight_env_t, input: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(arg orelse return));
    const text = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input)), 0);
    // JS mode: the buffer is raw JS, so highlight it as such (plus `$LP_*` refs).
    if (self.js_mode) {
        highlightJavaScript(henv, text);
        return;
    }
    const cmd_start = skipWhitespace(text, 0) orelse return;
    var i = cmd_start;
    while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
    const cmd = text[cmd_start..i];
    // Commit to red once the cursor moves past the token, OR as soon as the
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
        // No leading `/`: a natural-language prompt, so no command validation.
        // Start at `cmd_start`, not `i`, so a `$LP_*` first token highlights too.
        highlightDollarVars(henv, text, cmd_start);
    }
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

/// Closest command name within two edits, or null — for "did you mean?" on typos.
pub fn closestCommand(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (all_slash_names) |cand| {
        const dist = editDistance(name, cand);
        if (dist < best_dist) {
            best_dist = dist;
            best = cand;
        }
    }
    return if (best_dist <= 2) best else null;
}

/// Case-insensitive Levenshtein distance. Returns `maxInt` for inputs longer
/// than the table (no slash command is that long).
fn editDistance(a: []const u8, b: []const u8) usize {
    const max = 32;
    if (a.len >= max or b.len >= max) return std.math.maxInt(usize);
    var dp: [max][max]usize = undefined;
    for (0..a.len + 1) |i| dp[i][0] = i;
    for (0..b.len + 1) |j| dp[0][j] = j;
    for (a, 1..) |ca, i| {
        for (b, 1..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            dp[i][j] = @min(@min(dp[i - 1][j] + 1, dp[i][j - 1] + 1), dp[i - 1][j - 1] + cost);
        }
    }
    return dp[a.len][b.len];
}

fn slashHasParams(name: []const u8) bool {
    if (Schema.findByName(name)) |s| return s.hints.len > 0;
    if (SlashCommand.findMeta(name)) |m| return m.hint.len > 0;
    return false;
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

/// Highlight `$LP_*` tokens appearing from `start` onward. `${…}` is not a
/// prompt substitution form, so interpolation stays off.
fn highlightDollarVars(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize) void {
    var i = start;
    while (js_highlight.nextDollarRef(text, i, text.len, false)) |ref| {
        c.ic_highlight(henv, @intCast(ref.start), @intCast(ref.end - ref.start), style_var.ptr);
        i = ref.end;
    }
}

/// Paints `js_highlight` spans onto isocline's cell attributes.
const IcSink = struct {
    henv: ?*c.ic_highlight_env_t,

    pub fn emit(self: IcSink, start: usize, len: usize, kind: js_highlight.Kind) void {
        const style: []const u8 = switch (kind) {
            .comment => style_comment,
            .string => style_string,
            .variable, .interpolation => style_var,
            .number => style_num,
            .keyword => style_keyword,
            .global => style_jsglobal,
            .function => style_fn,
            .method => style_method,
            .type_name => style_type,
        };
        c.ic_highlight(self.henv, @intCast(start), @intCast(len), style.ptr);
    }
};

/// Highlight the buffer as JavaScript. Byte offsets are safe (see
/// `highlighterCallback`): every token boundary is an ASCII byte and non-ASCII
/// bytes advance singly without being highlighted.
fn highlightJavaScript(henv: ?*c.ic_highlight_env_t, text: []const u8) void {
    const sink: IcSink = .{ .henv = henv };
    _ = js_highlight.tokenize(text, .normal, sink);
}

fn highlightSlashArgs(henv: ?*c.ic_highlight_env_t, text: []const u8, start: usize) void {
    var i = start;
    while (skipWhitespace(text, i)) |tok_start| {
        i = tok_start;
        if (text[i] == '\'' or text[i] == '"') {
            i = Schema.quotedSpanEnd(text, i);
            c.ic_highlight(henv, @intCast(tok_start), @intCast(i - tok_start), style_string.ptr);
            continue;
        }
        while (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != '=') i += 1;
        const key_end = i;
        if (i < text.len and text[i] == '=') {
            c.ic_highlight(henv, @intCast(tok_start), @intCast(key_end - tok_start), style_key.ptr);
            i += 1;
            const val_start = i;
            if (i < text.len and (text[i] == '\'' or text[i] == '"')) {
                i = Schema.quotedSpanEnd(text, i);
                c.ic_highlight(henv, @intCast(val_start), @intCast(i - val_start), style_string.ptr);
            } else {
                while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
                highlightBareToken(henv, text, val_start, i);
            }
        }
    }
}

pub fn setIdleCallback(fun: ?*const c.ic_idle_fun_t, arg: ?*anyopaque) void {
    c.ic_set_idle_callback(fun, arg);
}

pub fn readLine(prompt: [*:0]const u8) ?[]const u8 {
    // Kitty-keyboard "disambiguate" (Ctrl+Enter as a distinct CSI-u, not bare
    // \r) only while isocline reads: while active, Ctrl-C arrives as a CSI-u
    // escape rather than raw \x03, so the tty driver raises no SIGINT. Leaving
    // it on during thinking/tool runs would make Ctrl-C unable to interrupt them.
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[>1u") catch {};
    defer _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[<u") catch {};
    // Isocline auto-appends the line to its (optionally-persisted) history.
    const line = c.ic_readline(prompt) orelse return null;
    return std.mem.sliceTo(line, 0);
}

pub fn freeLine(line: []const u8) void {
    c.ic_free(@ptrCast(@constCast(line.ptr)));
}

const continuation_prompt = "... ";

/// Read the follow-up lines of an input whose `'''…'''` body is still open,
/// joined with newlines until the block closes. Null abandons the input
/// (EOF on the continuation prompt, or out of memory).
pub fn readContinuation(arena: std.mem.Allocator, first: []const u8) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, first) catch return null;
    while (Schema.hasUnclosedTripleQuote(buf.items)) {
        const next = readLine(continuation_prompt) orelse return null;
        defer freeLine(next);
        buf.append(arena, '\n') catch return null;
        buf.appendSlice(arena, next) catch return null;
    }
    return buf.items;
}

// Free-function `lp.log.sink` can't capture self; the agent sets this
// before installing the sink and clears it on teardown.
var active_for_log: ?*Terminal = null;

pub fn installLogSink(self: *Terminal) void {
    active_for_log = self;
    lp.log.sink = logSink;
}

pub fn uninstallLogSink(self: *Terminal) void {
    _ = self;
    lp.log.sink = null;
    active_for_log = null;
}

fn logSink(bytes: []const u8) void {
    if (active_for_log) |t| {
        // REPL already surfaces the clean `● ...` outcome line
        if (t.isRepl()) return;
        if (t.spinner.emitAbove(bytes)) return;
    }
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    _ = std.posix.write(std.posix.STDERR_FILENO, bytes) catch {};
}

/// Current terminal width in columns, queried via TIOCGWINSZ on stderr.
/// Null when stderr isn't a tty, the ioctl fails, or the kernel reports 0
/// (some pseudo-ttys leave the field unset). Cheap enough to call per render
/// frame; picks up resizes without SIGWINCH plumbing.
pub fn columns() ?u16 {
    var ws: std.posix.winsize = undefined;
    // bitcast via c_uint: on archs where `_IOR` sets the direction bit
    // (MIPS/PPC/SPARC), `IOCGWINSZ` exceeds i32 range, so a plain @intCast
    // panics; the bitcast preserves the bit pattern.
    const req: c_int = @bitCast(@as(c_uint, std.posix.T.IOCGWINSZ));
    const rc = std.c.ioctl(std.posix.STDERR_FILENO, req, &ws);
    if (rc != 0 or ws.col == 0) return null;
    return ws.col;
}

/// Erase the frame after an empty submit. The bars collapse on submit, leaving
/// the spacing and prompt lines with the cursor one line below; move up two,
/// clear to end of screen.
pub fn clearPromptFrame(self: *Terminal) void {
    if (!self.isRepl()) return;
    std.debug.print("\x1b[2A\r\x1b[J", .{});
}

pub fn interactiveTty() bool {
    return std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDERR_FILENO);
}

/// Numbered TTY picker. `default` (if set) marks that row "(default)" and
/// makes Enter start on that index. Up/Down moves the active row; Enter
/// selects it. Numbered input still works for users who prefer typing.
pub fn promptNumberedChoice(header: []const u8, items: []const [:0]const u8, default: ?usize) !usize {
    if (items.len == 0) return error.NoChoice;
    const valid_default: ?usize = if (default) |d| if (d < items.len) d else null else null;
    if (interactiveTty()) {
        return promptInteractiveChoice(header, items, valid_default) catch |err| switch (err) {
            error.NotInteractive => try promptNumberedChoiceLine(header, items, valid_default),
            else => err,
        };
    }
    return promptNumberedChoiceLine(header, items, valid_default);
}

/// Line-oriented fallback. Errors with NoChoice after 3 invalid attempts.
fn promptNumberedChoiceLine(header: []const u8, items: []const [:0]const u8, default: ?usize) !usize {
    var stdin_buf: [128]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        std.debug.print("{s}\n", .{header});
        for (items, 0..) |item, idx| {
            const marker: []const u8 = if (default) |d| (if (d == idx) " (default)" else "") else "";
            std.debug.print("  {d:>3}) {s}{s}\n", .{ idx + 1, item, marker });
        }
        std.debug.print("> ", .{});

        const line = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.StreamTooLong, error.ReadFailed => return error.UserCancelled,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            if (default) |d| return d;
            std.debug.print("Invalid input — type a number.\n", .{});
            continue;
        }
        const choice = std.fmt.parseInt(usize, trimmed, 10) catch {
            const hint: []const u8 = if (default != null) " (or press Enter for default)" else "";
            std.debug.print("Invalid input — type a number{s}.\n", .{hint});
            continue;
        };
        if (choice >= 1 and choice <= items.len) return choice - 1;
        std.debug.print("Out of range.\n", .{});
    }
    return error.NoChoice;
}

const ChoiceInput = enum { up, down, enter, cancel, ignore };

const ChoiceState = struct {
    selected: usize,

    fn init(default: ?usize) ChoiceState {
        return .{ .selected = default orelse 0 };
    }

    fn apply(self: *ChoiceState, input: ChoiceInput, item_count: usize) ?usize {
        switch (input) {
            .up => self.selected = if (self.selected == 0) item_count - 1 else self.selected - 1,
            .down => self.selected = (self.selected + 1) % item_count,
            .enter => return self.selected,
            .cancel, .ignore => {},
        }
        return null;
    }
};

const RawTerminal = struct {
    original: std.posix.termios,

    fn enable() !RawTerminal {
        if (!interactiveTty()) return error.NotInteractive;
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        // Under the REPL's kitty "disambiguate" flag, cursor keys arrive as
        // CSI-u the byte reader can't parse; push flag 0 to force legacy arrow
        // encoding. restore() pops back to the REPL's flag.
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[>0u") catch {};
        return .{ .original = original };
    }

    fn restore(self: *const RawTerminal) void {
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[<u") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

fn promptInteractiveChoice(header: []const u8, items: []const [:0]const u8, default: ?usize) !usize {
    var raw = try RawTerminal.enable();
    defer raw.restore();

    var state = ChoiceState.init(default);
    const line_count = items.len + 2;
    var first_render = true;
    while (true) {
        renderChoice(header, items, default, state.selected, first_render);
        first_render = false;

        const input = readChoiceInput() catch return error.UserCancelled;
        if (input == .cancel) {
            clearChoiceRender(line_count);
            return error.UserCancelled;
        }
        if (state.apply(input, items.len)) |idx| {
            clearChoiceRender(line_count);
            std.debug.print("{s} {s}\r\n", .{ header, items[idx] });
            return idx;
        }
    }
}

fn clearChoiceRender(line_count: usize) void {
    moveChoiceRenderStart(line_count);
    for (0..line_count) |i| {
        std.debug.print(ansi.clear_line, .{});
        if (i + 1 < line_count) std.debug.print("\r\n", .{});
    }
    moveChoiceRenderStart(line_count);
}

fn moveChoiceRenderStart(line_count: usize) void {
    if (line_count > 1) {
        std.debug.print("\x1b[{d}F", .{line_count - 1});
    } else {
        std.debug.print("\r", .{});
    }
}

fn renderChoice(header: []const u8, items: []const [:0]const u8, default: ?usize, selected: usize, first_render: bool) void {
    if (!first_render) moveChoiceRenderStart(items.len + 2);
    std.debug.print(ansi.clear_line ++ "{s}\r\n", .{header});
    for (items, 0..) |item, idx| {
        const on_row = idx == selected;
        const marker: []const u8 = if (on_row) ">" else " ";
        const style: []const u8 = if (on_row) ansi.bold ++ ansi.teal else "";
        const reset: []const u8 = if (on_row) ansi.reset else "";
        const default_marker: []const u8 = if (default) |d| (if (d == idx) " (default)" else "") else "";
        std.debug.print(ansi.clear_line ++ "  {s} {s}{s}{s}{s}\r\n", .{ marker, style, item, default_marker, reset });
    }
    std.debug.print(ansi.clear_line ++ "{s}Use Up/Down then Enter. Esc cancels.{s}", .{ ansi.dim, ansi.reset });
}

fn readChoiceInput() !ChoiceInput {
    while (true) {
        const ch = try readChoiceByte() orelse continue;
        return switch (ch) {
            3, 4, 27 => esc: {
                if (ch != 27) break :esc .cancel;
                const b1 = try readChoiceByte() orelse break :esc .cancel;
                if (b1 != '[' and b1 != 'O') break :esc .cancel;
                const b2 = try readChoiceByte() orelse break :esc .cancel;
                break :esc switch (b2) {
                    'A' => .up,
                    'B' => .down,
                    else => .ignore,
                };
            },
            '\r', '\n' => .enter,
            else => .ignore,
        };
    }
}

fn readChoiceByte() !?u8 {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| switch (err) {
        error.WouldBlock => return null,
        error.InputOutput => return error.ReadFailed,
        else => return err,
    };
    if (n == 0) return null;
    return buf[0];
}

test "ChoiceState: arrows wrap and enter selects highlighted item" {
    var state = ChoiceState.init(null);
    try std.testing.expectEqual(@as(usize, 0), state.selected);

    try std.testing.expectEqual(@as(?usize, null), state.apply(.up, 3));
    try std.testing.expectEqual(@as(usize, 2), state.selected);

    try std.testing.expectEqual(@as(?usize, null), state.apply(.down, 3));
    try std.testing.expectEqual(@as(usize, 0), state.selected);

    try std.testing.expectEqual(@as(?usize, 0), state.apply(.enter, 3));
}

test "ChoiceState: starts on default and enter returns it" {
    var state = ChoiceState.init(2);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    try std.testing.expectEqual(@as(?usize, 2), state.apply(.enter, 3));
}

test "valueAt: enum field via positional and kv, partial and empty" {
    const schema = Schema.findByName("waitForState").?;

    // Leading positional, nothing typed: empty partial, not kv.
    {
        const v = valueAt(schema, "", true).?;
        try std.testing.expect(v.field.enum_values.len > 0);
        try std.testing.expectEqualStrings("", v.partial);
        try std.testing.expect(!v.kv);
    }
    // Leading positional, partial value.
    {
        const v = valueAt(schema, "net", false).?;
        try std.testing.expectEqualStrings("net", v.partial);
        try std.testing.expect(!v.kv);
    }
    // Explicit `state=` with empty value.
    {
        const v = valueAt(schema, "state=", false).?;
        try std.testing.expectEqualStrings("", v.partial);
        try std.testing.expect(v.kv);
    }
    // Explicit `state=net`.
    {
        const v = valueAt(schema, "state=net", false).?;
        try std.testing.expectEqualStrings("net", v.partial);
        try std.testing.expect(v.kv);
    }
    // Past the only required field — timeout is not an enum, so no value match.
    {
        const v = valueAt(schema, "networkidle timeout=", false).?;
        try std.testing.expectEqual(@as(usize, 0), v.field.enum_values.len);
    }
}

test "valueAt: getEnv binds the leading positional to its optional name field" {
    const schema = Schema.findByName("getEnv").?;
    // `/getEnv ` — fresh positional, even though `name` is optional (0 required).
    {
        const v = valueAt(schema, "", true).?;
        try std.testing.expectEqualStrings("name", v.field.name);
        try std.testing.expectEqualStrings("", v.partial);
        try std.testing.expect(!v.kv);
    }
    // `/getEnv LP_H` — partial value bound to `name`.
    {
        const v = valueAt(schema, "LP_H", false).?;
        try std.testing.expectEqualStrings("name", v.field.name);
        try std.testing.expectEqualStrings("LP_H", v.partial);
    }
}

test "renderSchemaHint: ghosts enum value once typing, keeps template when empty" {
    const schema = Schema.findByName("waitForState").?;

    const hintStr = struct {
        fn f(p: [*c]const u8) ?[]const u8 {
            if (p == null) return null;
            return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(p)), 0);
        }
    }.f;

    // Nothing typed yet: the `<state> …` template, not an arbitrary value.
    try std.testing.expectEqualStrings(" <state> [timeout=…]", hintStr(renderSchemaHint(schema, "", false)).?);

    // Partial positional ghosts the suffix of the first matching value.
    try std.testing.expectEqualStrings("workalmostidle", hintStr(renderSchemaHint(schema, "net", false)).?);

    // `state=` ghosts the first value.
    try std.testing.expectEqualStrings("load", hintStr(renderSchemaHint(schema, "state=", false)).?);
}

test {
    _ = md_term;
}

/// Style only for the interactive REPL on a real terminal; `--task`/piped
/// output stays verbatim so it can be consumed programmatically.
fn styledOutput(self: *const Terminal) bool {
    return self.isRepl() and self.stdout_is_tty;
}

/// Buffered, error-swallowing markdown write to stdout; only called on the
/// styled (REPL tty) path.
fn renderStyled(self: *Terminal, text: []const u8, op: enum { full, delta, end }) void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stdout().writerStreaming(&buf);
    const w = &fw.interface;
    switch (op) {
        .full => {
            md_term.render(w, text) catch {};
            w.writeByte('\n') catch {};
        },
        .delta => self.md_stream.feed(w, text) catch {},
        .end => {
            self.md_stream.close(w) catch {};
            w.writeByte('\n') catch {};
        },
    }
    w.flush() catch {};
}

pub fn printAssistant(self: *Terminal, text: []const u8) void {
    if (text.len == 0) return;
    if (self.styledOutput()) return self.renderStyled(text, .full);
    _ = std.posix.write(std.posix.STDOUT_FILENO, text) catch {};
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
}

/// Write a streamed assistant-text delta (no trailing newline). Rendered
/// line-buffered through `md_stream` on a REPL tty, verbatim otherwise. The
/// caller must pause the spinner first (its stderr frames would otherwise
/// interleave with this stdout text) and call `endAssistantStream` when the
/// stream ends.
pub fn printAssistantDelta(self: *Terminal, text: []const u8) void {
    if (text.len == 0) return;
    if (self.styledOutput()) return self.renderStyled(text, .delta);
    _ = std.posix.write(std.posix.STDOUT_FILENO, text) catch {};
}

/// Flush any partial streamed line, terminate it, and reset stream state.
pub fn endAssistantStream(self: *Terminal) void {
    if (self.styledOutput()) return self.renderStyled("", .end);
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
}

// Must exceed the downstream LLM-judge's snapshot window for full grounding
// evidence. Does not cap the agent's own LLM, which gets up to
// tool_output_max_bytes (1 MiB) via Agent.zig:capToolOutput. Bypassed in REPL
// where the human can scroll.
const max_result_display_len = 2000;

/// Tool-outcome line shared by REPL slash commands and LLM tool calls.
/// REPL: green ● on success, red ● on error. Non-REPL prefixes `[result:
/// name]`; success gates on `medium+`, errors bypass the gate so a failing
/// script still surfaces *why* at default verbosity.
pub fn printToolOutcome(self: *Terminal, name: []const u8, text: []const u8, is_error: bool) void {
    if (self.repl_arena) |*a| {
        defer _ = a.reset(.retain_capacity);
        const bytes = formatReplOutcome(a.allocator(), text, is_error) catch return;
        if (self.spinner.emitAbove(bytes)) return;
        _ = std.posix.write(std.posix.STDERR_FILENO, bytes) catch {};
        return;
    }
    if (!is_error and !self.verbosity.atLeast(.medium)) return;
    const truncated = text[0..@min(text.len, max_result_display_len)];
    const ellipsis: []const u8 = if (text.len > max_result_display_len) "..." else "";
    const color: []const u8 = if (is_error) ansi.red else ansi.green;
    std.debug.print("{s}{s}[result: {s}]{s} {s}{s}\n", .{ ansi.dim, color, name, ansi.reset, truncated, ellipsis });
}

/// Freeze the script spinner into a green bullet for a `/load` run that
/// produced no output — mirrors a `/goto` outcome line, swapping the braille
/// glyph for a `●`. Only fires when the spinner was shown (REPL + TTY);
/// otherwise the run leaves just its own output.
pub fn printScriptDone(self: *Terminal, name: []const u8, args: []const u8) void {
    if (!self.spinner.isEnabled()) return;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        ansi.green ++ "●" ++ ansi.reset ++ " " ++ ansi.dim ++ "[{s} {s}]" ++ ansi.reset ++ "\n",
        .{ name, args },
    ) catch return;
    _ = std.posix.write(std.posix.STDERR_FILENO, line) catch {};
}

/// Re-indents `text` as two-space JSON, or null when it isn't a JSON object/array.
/// The `{`/`[` sniff skips the parse for the common plain-text case — `text` may
/// be up to 1 MiB.
pub fn reindentJson(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, text, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(parsed, .{ .whitespace = .indent_2 }, &aw.writer) catch return null;
    return aw.written();
}

/// REPL outcome line: colored ● marker followed by the body, pretty-printed if
/// JSON. Builds the whole payload in the arena so callers can route it past the
/// spinner (`emitAbove`) without interleaving with frame writes.
fn formatReplOutcome(arena: std.mem.Allocator, text: []const u8, is_error: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    const pretty = reindentJson(arena, text);
    const sep: []const u8 = if (pretty != null) "\n" else " ";
    const color: []const u8 = if (is_error) ansi.red else ansi.green;
    try w.print("{s}●{s}{s}", .{ color, ansi.reset, sep });
    try w.writeAll(pretty orelse text);
    try w.writeByte('\n');
    return aw.written();
}

pub fn printError(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    self.printSeverity(ansi.red, "Error", fmt, args);
}

pub fn printWarning(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    self.printSeverity(ansi.yellow, "Warning", fmt, args);
}

fn printSeverity(self: *Terminal, color: []const u8, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (self.repl_arena) |*a| {
        defer _ = a.reset(.retain_capacity);
        var aw: std.Io.Writer.Allocating = .init(a.allocator());
        aw.writer.print("{s}●{s} " ++ fmt ++ "\n", .{ color, ansi.reset } ++ args) catch return;
        const bytes = aw.written();
        if (self.spinner.emitAbove(bytes)) return;
        _ = std.posix.write(std.posix.STDERR_FILENO, bytes) catch {};
        return;
    }
    std.debug.print("{s}{s}{s}: " ++ fmt ++ "{s}\n", .{ ansi.bold, color, label } ++ args ++ .{ansi.reset});
}

pub fn printInfo(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    if (!self.isRepl() and !self.verbosity.atLeast(.medium)) return;
    std.debug.print(fmt ++ "\n", args);
}

pub fn printDimmed(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    if (!self.isRepl() and !self.verbosity.atLeast(.medium)) return;
    std.debug.print(ansi.dim ++ fmt ++ ansi.reset ++ "\n", args);
}

pub fn printItalic(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    if (!self.isRepl() and !self.verbosity.atLeast(.medium)) return;
    std.debug.print(ansi.italic ++ fmt ++ ansi.reset ++ "\n", args);
}

fn helpLessThan(_: void, a: SlashCommand.Help, b: SlashCommand.Help) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Sort `rows` by name and list them under `header` as `/cmd — description`.
pub fn printHelpSection(self: *Terminal, header: []const u8, rows: []SlashCommand.Help) void {
    if (rows.len == 0) return;
    std.sort.pdq(SlashCommand.Help, rows, {}, helpLessThan);
    self.printInfo("{s}{s}{s}", .{ ansi.bold, header, ansi.reset });
    for (rows) |r| self.printInfo("  " ++ highlightCmd("/{s}") ++ " — {s}", .{ r.name, r.description });
}

/// Render a slash-command parse error, with a "did you mean?" suggestion for
/// unknown commands and a field/type hint when a value failed to coerce.
pub fn printSlashParseError(self: *Terminal, err: Schema.ParseError, name: []const u8, diag: ?*const Schema.Diag) void {
    if (err == error.InvalidValue) {
        if (diag) |d| if (d.bad_field.len > 0) {
            self.printError("{s}: {s}: expected {s}, got '{s}'. Try /help {s}.", .{ name, d.bad_field, @tagName(d.expected_type), d.bad_value, name });
            return;
        };
    }
    const reason: []const u8 = switch (err) {
        error.UnknownTool => {
            if (closestCommand(name)) |near| {
                return self.printError("{s}: unknown command. Did you mean " ++ highlightCmd("/{s}") ++ "? Try /help.", .{ name, near });
            }
            return self.printError("{s}: unknown command. Try /help.", .{name});
        },
        error.MissingName => return self.printError("missing command name. Try /help.", .{}),
        error.MissingRequired => "missing required argument",
        error.MalformedKv => "malformed key=value. Use key=value or {json}",
        error.UnknownField => "unknown field (typo?)",
        error.DuplicateField => "the same field was supplied twice (check for case-variants like Selector vs selector)",
        error.PositionalNotAllowed => "positional only works for commands with one required field. Use key=value",
        error.PositionalMustComeFirst => "the positional value must come before key=value pairs",
        error.UnterminatedQuote => "unterminated quote",
        error.UnsupportedEscape => "backslash escapes aren't supported in quoted values; use the other quote style or `'''…'''`",
        error.InvalidValue => "invalid value (check argument type)",
        error.OutOfMemory => return self.printError("out of memory", .{}),
    };
    self.printError("{s}: {s}. Try /help {s}.", .{ name, reason, name });
}

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
const Config = lp.Config;
const Schema = lp.Schema;
const SlashCommand = @import("SlashCommand.zig");
const Spinner = @import("Spinner.zig");
const md_term = @import("md_term.zig");
const prompt_assist = @import("prompt_assist.zig");
const ansi = @import("ansi.zig");
const c = @cImport({
    @cInclude("isocline.h");
});

const Terminal = @This();

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
/// Prompt-assist C-callback state; `attachCompleter` registers its address,
/// so the Terminal must sit at its final location by then.
assist: prompt_assist.State,
/// Line-buffered markdown state for streamed assistant deltas; its `close`
/// resets everything so fence state can't leak into the next message. Only
/// used on the styled (REPL tty) path, hence the placeholder.
md_stream: md_term.Stream = .{ .show_table_placeholder = true },

pub const CompletionSource = prompt_assist.CompletionSource;
pub const HistoryPaths = prompt_assist.HistoryPaths;

/// Wires the isocline completer, hinter, and highlighter to `self.assist`.
/// Must run after the Terminal is in its final memory location and before
/// the first `readLine`.
pub fn attachCompleter(self: *Terminal, source: ?CompletionSource) void {
    self.assist.completion_source = source;
    prompt_assist.attach(&self.assist);
}

pub fn jsMode(self: *const Terminal) bool {
    return self.assist.js_mode;
}

pub fn init(allocator: std.mem.Allocator, history_paths: ?HistoryPaths, verbosity: Verbosity, is_repl: bool) Terminal {
    if (is_repl) prompt_assist.setupRepl();
    const stderr_is_tty = std.posix.isatty(std.posix.STDERR_FILENO);
    return .{
        .allocator = allocator,
        .verbosity = verbosity,
        .repl_arena = if (is_repl) std.heap.ArenaAllocator.init(allocator) else null,
        .stderr_is_tty = stderr_is_tty,
        .stdout_is_tty = std.posix.isatty(std.posix.STDOUT_FILENO),
        .spinner = .init(is_repl, stderr_is_tty),
        .assist = .{ .history_paths = history_paths },
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

pub fn setIdleCallback(fun: ?*const c.ic_idle_fun_t, arg: ?*anyopaque) void {
    c.ic_set_idle_callback(fun, arg);
}

pub fn readLine(prompt: [*:0]const u8) ?[]const u8 {
    // Kitty-keyboard "disambiguate" (Ctrl+Enter as a distinct CSI-u, not bare
    // \r) only while isocline reads: while active, Ctrl-C arrives as a CSI-u
    // escape rather than raw \x03, so the tty driver raises no SIGINT. Leaving
    // it on during thinking/tool runs would make Ctrl-C unable to interrupt them.
    _ = std.posix.write(std.posix.STDOUT_FILENO, ansi.kitty_disambiguate) catch {};
    defer _ = std.posix.write(std.posix.STDOUT_FILENO, ansi.kitty_pop) catch {};
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

/// Erase the frame after an empty submit. The bars collapse on submit, leaving
/// the spacing and prompt lines with the cursor one line below; move up two,
/// clear to end of screen.
pub fn clearPromptFrame(self: *Terminal) void {
    if (!self.isRepl()) return;
    std.debug.print("\x1b[2A\r\x1b[J", .{});
}

test {
    _ = md_term;
    _ = prompt_assist;
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
            if (SlashCommand.closestCommand(name)) |near| {
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

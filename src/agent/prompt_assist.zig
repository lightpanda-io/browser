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

//! The REPL prompt's input assistance: isocline completion, ghost hints, and
//! syntax highlighting over the slash-command schemas and JS mode. Terminal
//! owns the readline lifecycle; this module owns everything that reacts to
//! the buffer while the user types.

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Schema = lp.Schema;
const SlashCommand = @import("SlashCommand.zig");
const js_highlight = @import("js_highlight.zig");
const c = @cImport({
    @cInclude("isocline.h");
});

const style_slash = "ps-slash";
const style_string = "ps-string";
const style_var = "ps-var";
const style_url = "ps-url";
const style_key = "ps-key";
const style_num = "ps-num";
const style_err = "ps-err";
const style_jsmode = "ps-jsmode";

/// The prompt's style palette (`ps-*` avoids isocline's built-in `ic-*`
/// namespace). Registration and token-kind painting both derive from it, so
/// a painted style is registered by construction.
const Style = struct {
    name: [:0]const u8,
    spec: [:0]const u8,
    /// `js_highlight` token kinds painted with this style; empty for styles
    /// applied directly by name.
    kinds: []const js_highlight.Kind = &.{},
};

const styles = [_]Style{
    .{ .name = style_slash, .spec = "ansi-teal bold" },
    .{ .name = style_string, .spec = "ansi-green", .kinds = &.{.string} },
    .{ .name = style_var, .spec = "ansi-yellow", .kinds = &.{ .variable, .interpolation } },
    .{ .name = style_url, .spec = "ansi-blue underline" },
    .{ .name = style_key, .spec = "ansi-blue" },
    .{ .name = style_num, .spec = "ansi-magenta", .kinds = &.{.number} },
    .{ .name = style_err, .spec = "ansi-red" },
    .{ .name = style_jsmode, .spec = "ansi-red bold" },
    .{ .name = "ps-keyword", .spec = "ansi-blue bold", .kinds = &.{.keyword} },
    .{ .name = "ps-comment", .spec = "ansi-darkgray italic", .kinds = &.{.comment} },
    .{ .name = "ps-jsglobal", .spec = "ansi-cyan", .kinds = &.{.global} },
    .{ .name = "ps-fn", .spec = "ansi-teal", .kinds = &.{.function} },
    .{ .name = "ps-method", .spec = "ansi-teal italic", .kinds = &.{.method} },
    .{ .name = "ps-type", .spec = "ansi-cyan", .kinds = &.{.type_name} },
};

/// Style name per token kind, derived from `styles`. Unmapped or
/// doubly-mapped kinds are compile errors.
const kind_styles = blk: {
    const n = std.enums.values(js_highlight.Kind).len;
    var arr: [n]?[:0]const u8 = @splat(null);
    for (styles) |s| for (s.kinds) |kind| {
        if (arr[@intFromEnum(kind)] != null) @compileError("kind styled twice: " ++ @tagName(kind));
        arr[@intFromEnum(kind)] = s.name;
    };
    var out: [n][:0]const u8 = undefined;
    for (arr, 0..) |name, i| {
        out[i] = name orelse @compileError("js_highlight.Kind with no ps-* style: " ++
            @tagName(@as(js_highlight.Kind, @enumFromInt(i))));
    }
    break :blk out;
};

/// Lets the completer/hinter pull dynamic candidates from the `Agent` without
/// this module depending on it (same idiom as `Session.cancel_hook`).
pub const CompletionSource = struct {
    context: *anyopaque,
    providers: *const fn (context: *anyopaque, arena: std.mem.Allocator) []const []const u8,
    /// May block on an HTTP fetch.
    models: *const fn (context: *anyopaque, arena: std.mem.Allocator) []const []const u8,
};

/// Separate history files for normal and JS prompt modes. isocline holds one
/// history list at a time, so we swap files on mode toggle rather than tag a
/// shared file.
pub const HistoryPaths = struct {
    normal: [:0]const u8,
    js: [:0]const u8,
};

/// The mutable state the C callbacks read: registered once via `attach`, so
/// it must live at a stable address.
pub const State = struct {
    /// True while the REPL is in JS mode; set by isocline's mode callback.
    js_mode: bool = false,
    completion_source: ?CompletionSource = null,
    /// Per-mode history files (null outside REPL mode). `modeCallback` swaps
    /// the active one so JS and normal recall stay separate.
    history_paths: ?HistoryPaths = null,
};

/// One-time isocline configuration for REPL mode. Probes the terminal
/// (isocline writes an ESC[6n cursor-report on stdout), so callers must skip
/// it in script-only mode.
pub fn setupRepl() void {
    _ = c.ic_enable_multiline(true);
    _ = c.ic_enable_hint(true);
    _ = c.ic_enable_inline_help(true);
    // Show ghost completions instantly; isocline's default is 400 ms.
    _ = c.ic_set_hint_delay(0);
    _ = c.ic_enable_brace_insertion(true);
    for (styles) |s| c.ic_style_def(s.name.ptr, s.spec.ptr);
    // lighten the ghost/inline-hint color from isocline's default ansi-darkgray
    c.ic_style_def("ic-hint", "ansi-color=244");
    // `!` on an empty prompt toggles JS mode; state callback wired in attach.
    c.ic_set_prompt_mode("[" ++ style_jsmode ++ "]![/" ++ style_jsmode ++ "] ", '!');
    // Blank continuation marker so multiline input isn't prefixed with `>`.
    c.ic_set_prompt_marker("❯ ", "");
    _ = c.ic_enable_highlight(true);
}

/// Wires the isocline completer, hinter, and highlighter to `state` and
/// loads the initial history. Must run after `state` is in its final memory
/// location and before the first readline.
pub fn attach(state: *State) void {
    c.ic_set_default_completer(&completionCallback, state);
    c.ic_set_default_hinter(&hintsCallback, state);
    c.ic_set_mode_callback(&modeCallback, state);
    c.ic_set_ctrl_d_hint("  press Ctrl-D again to exit");
    c.ic_set_esc_clear_hint("  esc again to clear");
    c.ic_set_mode_hint("  JS mode - esc to exit");
    c.ic_set_default_highlighter(&highlighterCallback, state);
    if (state.history_paths) |hp| {
        // Mode inactive at launch, so load the normal file; modeCallback
        // swaps to JS on mode entry.
        c.ic_set_history(hp.normal.ptr, -1); // -1 → 200-entry default cap
    }
}

fn modeCallback(active: bool, arg: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(arg orelse return));
    state.js_mode = active;
    if (state.history_paths) |hp| {
        c.ic_set_history((if (active) hp.js else hp.normal).ptr, -1);
    }
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
    const arg = std.mem.trimStart(u8, input[help_arg_prefix.len..], " ");
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
    state: *State,
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
    if (state.completion_source) |src| switch (meta.tag) {
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

/// Directory entries whose basename completes the partial path `body`
/// (`dir/ba` → entries of `dir/` prefix-matching `ba`). Returned names
/// borrow the iterator; use before the next `next()`.
const PathMatchIterator = struct {
    dir: std.Io.Dir,
    it: std.Io.Dir.Iterator,
    /// `body` up to and including its last `/`; kept verbatim in candidates.
    dir_part: []const u8,
    base: []const u8,

    const Match = struct { name: []const u8, is_dir: bool };

    fn init(body: []const u8) ?PathMatchIterator {
        const slash = std.mem.lastIndexOfScalar(u8, body, '/');
        const dir_part = if (slash) |i| body[0 .. i + 1] else "";
        const open_path = if (dir_part.len == 0) "." else dir_part;
        const dir = std.Io.Dir.cwd().openDir(lp.io, open_path, .{ .iterate = true }) catch return null;
        return .{
            .dir = dir,
            .it = dir.iterate(),
            .dir_part = dir_part,
            .base = body[dir_part.len..],
        };
    }

    fn deinit(self: *PathMatchIterator) void {
        self.dir.close(lp.io);
    }

    fn next(self: *PathMatchIterator) ?Match {
        while (self.it.next(lp.io) catch return null) |entry| {
            if (!std.ascii.startsWithIgnoreCase(entry.name, self.base)) continue;
            return .{ .name = entry.name, .is_dir = entry.kind == .directory };
        }
        return null;
    }
};

fn addPathCompletions(
    cenv: ?*c.ic_completion_env_t,
    input: []const u8,
    body: []const u8,
    prefix: []const u8,
    buf: *[completion_buf_len:0]u8,
) void {
    var matches = PathMatchIterator.init(body) orelse return;
    defer matches.deinit();

    var name_buf: [completion_buf_len]u8 = undefined;
    while (matches.next()) |m| {
        const suffix: []const u8 = if (m.is_dir) "/" else "";
        const full = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ matches.dir_part, m.name }) catch continue;
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
    const state: *State = @ptrCast(@alignCast(c.ic_completion_arg(cenv) orelse return));
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(prefix)), 0);

    var buf: [completion_buf_len:0]u8 = undefined;

    // `/help <name>`: arg is a command name, not a value — skip env-var fallthrough.
    if (parseHelpArgPrefix(input)) |partial| {
        for (SlashCommand.all_names) |name| addPrefixedCompletion(cenv, &buf, input, help_arg_prefix, name, "", partial);
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
            for (SlashCommand.all_names) |name| {
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
                    addMetaValueCompletions(state, cenv, input, parts.rest, meta, &buf);
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
    const state: *State = @ptrCast(@alignCast(arg orelse return null));
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input_c)), 0);

    // JS mode: the buffer is raw JS, so slash/kv hints don't apply.
    if (state.js_mode) return null;

    if (input.len == 0) return null;

    if (parseHelpArgPrefix(input)) |partial| return ghostFirstMatch(&SlashCommand.all_names, partial, "");

    // Inside an open `'''…'''` body the buffer is script text, not kv args.
    if (Schema.hasUnclosedTripleQuote(input)) return null;

    if (std.mem.eql(u8, input, "/")) return ghostFirstMatch(&SlashCommand.all_names, "", "");

    if (Schema.parseSlashCommand(input)) |parts| {
        const ends_ws = input[input.len - 1] == ' ';
        if (Schema.findByName(parts.name)) |schema| {
            return renderSchemaHint(schema, parts.rest, ends_ws);
        }
        if (SlashCommand.findMeta(parts.name)) |meta| {
            return renderMetaHint(state, meta, parts.rest, ends_ws);
        }
        if (std.mem.indexOfScalar(u8, input, ' ') == null) {
            return ghostFirstMatch(&SlashCommand.all_names, parts.name, "");
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
fn renderMetaHint(state: *State, meta: *const SlashCommand.MetaCommand, body: []const u8, ends_ws: bool) [*c]const u8 {
    if (meta.hint.len == 0) return null;
    if (ends_ws and body.len != 0) return null; // value already committed

    if (state.completion_source) |src| {
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

fn ghostPathFirstMatch(body: []const u8) [*c]const u8 {
    var matches = PathMatchIterator.init(body) orelse return null;
    defer matches.deinit();
    const m = matches.next() orelse return null;
    const suffix: []const u8 = if (m.is_dir) "/" else "";
    const text = std.fmt.bufPrintZ(&hint_buf, "{s}{s}", .{ m.name[matches.base.len..], suffix }) catch return null;
    return text.ptr;
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

/// Byte offsets to ic_highlight are not UTF-8 code points; safe because we
/// only tokenize on ASCII boundaries (whitespace, quotes, `=`, `$`).
fn highlighterCallback(henv: ?*c.ic_highlight_env_t, input: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(arg orelse return));
    const text = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(input)), 0);
    // JS mode: the buffer is raw JS, so highlight it as such (plus `$LP_*` refs).
    if (state.js_mode) {
        highlightJavaScript(henv, text);
        return;
    }
    const cmd_start = std.mem.indexOfNonePos(u8, text, 0, &std.ascii.whitespace) orelse return;
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
    for (SlashCommand.all_names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

fn slashHasPrefix(name: []const u8) bool {
    for (SlashCommand.all_names) |n| {
        if (std.ascii.startsWithIgnoreCase(n, name)) return true;
    }
    return false;
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
        c.ic_highlight(self.henv, @intCast(start), @intCast(len), kind_styles[@intFromEnum(kind)].ptr);
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
    while (std.mem.indexOfNonePos(u8, text, i, &std.ascii.whitespace)) |tok_start| {
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

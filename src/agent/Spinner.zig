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
const log = lp.log;
const Terminal = @import("Terminal.zig");
const ansi = Terminal.ansi;
const truncateUtf8 = @import("../string.zig").truncateUtf8;

const Spinner = @This();

const braille = [_][]const u8{ "⡇", "⣆", "⣤", "⣰", "⢸", "⠹", "⠛", "⠏" };
const interval_ns: u64 = 100 * std.time.ns_per_ms;
/// Minimum dwell on a tool label so the user can read it. Slow tools exceed
/// it naturally; fast ones (getUrl, getCookies) get padded.
const min_tool_display_ns: u64 = 1500 * std.time.ns_per_ms;
const clear_eol = ansi.clear_eol;

const max_args_bytes: usize = 256;
const frame_buf_bytes: usize = 512;
/// Visual ceiling on the args slice. With the terminal-width cap, keeps the
/// spinner line single-row even when the script body is huge.
const max_args_cells: usize = 70;
/// UTF-8 horizontal ellipsis ("…") — 3 bytes, 1 visual cell.
const ellipsis = "\xe2\x80\xa6";
const ellipsis_cells: usize = 1;

const ToolState = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    args_buf: [max_args_bytes]u8 = undefined,
    args_len: usize = 0,
    /// Wall-clock at which `setTool` last fired; gates dwell-honoring.
    set_ns: i128 = 0,
    /// Worker should flip back to thinking once dwell elapses. A fresh
    /// `setTool` clears it, overriding the dwell with a new label.
    dwell_pending: bool = false,
    /// User-typed REPL commands drop the `agent:` framing: no agent is
    /// involved, it's lightpanda running the command directly.
    manual: bool = false,
};

const State = union(enum) {
    idle,
    thinking,
    tool: ToolState,
};

/// Atomic so the unlocked fast-path reads (`isEnabled`) don't race the
/// under-lock write in `ensureWorkerLocked`.
enabled: std.atomic.Value(bool),

mu: std.Thread.Mutex = .{},
cv: std.Thread.Condition = .{},
state: State = .idle,
frame: u8 = 0,

tool_calls: u32 = 0,
turn_started_ns: i128 = 0,

thread: ?std.Thread = null,
should_exit: bool = false,

last_render_buf: [frame_buf_bytes]u8 = undefined,
last_render_len: usize = 0,

pub fn init(is_repl: bool, stderr_is_tty: bool) Spinner {
    return .{ .enabled = .init(is_repl and stderr_is_tty) };
}

pub inline fn isEnabled(self: *const Spinner) bool {
    return self.enabled.load(.monotonic);
}

pub fn deinit(self: *Spinner) void {
    if (self.thread) |t| {
        self.mu.lock();
        self.should_exit = true;
        self.cv.signal();
        self.mu.unlock();
        t.join();
        self.thread = null;
    }
}

/// Spawns the worker thread on first call.
pub fn start(self: *Spinner) void {
    if (!self.isEnabled()) return;
    self.mu.lock();
    defer self.mu.unlock();
    self.state = .thinking;
    self.frame = 0;
    self.tool_calls = 0;
    self.turn_started_ns = std.time.nanoTimestamp();
    self.ensureWorkerLocked();
    self.cv.signal();
}

fn ensureWorkerLocked(self: *Spinner) void {
    if (self.thread == null) {
        self.thread = std.Thread.spawn(.{}, workerLoop, .{self}) catch |err| blk: {
            log.warn(.app, "spinner thread spawn failed", .{ .err = @errorName(err) });
            self.enabled.store(false, .monotonic);
            self.state = .idle;
            self.last_render_len = 0;
            break :blk null;
        };
    }
}

/// End an agent turn cleanly: clear the indicator, commit a one-line summary,
/// reset state. Called from a `defer` in agent code so it always runs.
pub fn stop(self: *Spinner) void {
    if (!self.isEnabled()) return;
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state == .idle) return;
    const elapsed_ns = std.time.nanoTimestamp() - self.turn_started_ns;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

    var buf: [frame_buf_bytes]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &buf,
        "\r" ++ clear_eol ++ ansi.dim ++ "[agent: worked for {d:.1}s · {d} tool call{s}]" ++ ansi.reset ++ "\n",
        .{ elapsed_s, self.tool_calls, if (self.tool_calls == 1) "" else "s" },
    ) catch return;
    _ = std.posix.write(std.posix.STDERR_FILENO, summary) catch {};

    self.state = .idle;
    self.last_render_len = 0;
}

/// End a turn with no commit. The caller is responsible for surfacing the
/// outcome — tool results, error messages, or summaries.
pub fn cancel(self: *Spinner) void {
    if (!self.isEnabled()) return;
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state == .idle) return;
    _ = std.posix.write(std.posix.STDERR_FILENO, "\r" ++ clear_eol) catch {};
    self.state = .idle;
    self.last_render_len = 0;
}

/// Switch the indicator to "running tool <name> <args>". Counts toward the
/// turn's tool-call total. Args are truncated to `max_args_bytes`. Called
/// without a preceding `start()` (state `.idle`), the label drops the `agent:`
/// prefix — that path is user-typed REPL commands, not LLM tool calls.
pub fn setTool(self: *Spinner, name: []const u8, args: []const u8) void {
    if (!self.isEnabled()) return;
    self.mu.lock();
    defer self.mu.unlock();
    const manual = self.state == .idle;
    self.tool_calls += 1;
    var tool: ToolState = .{ .set_ns = std.time.nanoTimestamp(), .manual = manual };
    const name_prefix = truncateUtf8(name, tool.name_buf.len);
    tool.name_len = name_prefix.len;
    @memcpy(tool.name_buf[0..name_prefix.len], name_prefix);
    // Strip control chars: a literal `\n` in args (e.g. /evaluate """…""" bodies)
    // breaks the `\r`-based redraw — `\r` only rewinds to the start of the last
    // line, leaving prior frames stuck on screen.
    const args_prefix = truncateUtf8(args, tool.args_buf.len);
    tool.args_len = args_prefix.len;
    for (args_prefix, 0..) |ch, i| {
        tool.args_buf[i] = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
    }
    self.state = .{ .tool = tool };
    // Manual paths skip `start()`, so spawn the worker on demand to drive the
    // braille animation.
    if (manual) self.ensureWorkerLocked();
    self.renderLocked();
    self.cv.signal();
}

/// Request a transition back to the cycling "thinking" state. The worker
/// honors `min_tool_display_ns`: if the current tool label has not been up
/// long enough, the flip is deferred until it has.
pub fn setThinking(self: *Spinner) void {
    if (!self.isEnabled()) return;
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .idle => return,
        .thinking => {},
        .tool => self.state.tool.dwell_pending = true,
    }
    self.cv.signal();
}

/// Print `text` (assumed to include its own newline) above the indicator,
/// then leave the indicator to repaint itself on the next tick.
pub fn emitAbove(self: *Spinner, text: []const u8) bool {
    if (!self.isEnabled()) return false;
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state == .idle) return false;
    _ = std.posix.write(std.posix.STDERR_FILENO, "\r" ++ clear_eol) catch {};
    _ = std.posix.write(std.posix.STDERR_FILENO, text) catch {};
    if (text.len == 0 or text[text.len - 1] != '\n') {
        _ = std.posix.write(std.posix.STDERR_FILENO, "\n") catch {};
    }
    self.last_render_len = 0;
    self.renderLocked();
    return true;
}

fn workerLoop(self: *Spinner) void {
    self.mu.lock();
    defer self.mu.unlock();
    while (!self.should_exit) {
        while (!self.should_exit and self.state == .idle) self.cv.wait(&self.mu);
        if (self.should_exit) return;

        switch (self.state) {
            .tool => {
                if (self.state.tool.dwell_pending) {
                    // Signed compare: a backward clock jump (NTP slew, suspend/resume)
                    // can make the delta negative; `@intCast` to u64 would panic.
                    const delta: i128 = std.time.nanoTimestamp() - self.state.tool.set_ns;
                    if (delta >= @as(i128, min_tool_display_ns)) {
                        self.state = .thinking;
                    }
                }
            },
            else => {},
        }

        self.renderLocked();

        self.frame = (self.frame + 1) % @as(u8, @intCast(braille.len));
        self.cv.timedWait(&self.mu, interval_ns) catch {};
    }
}

fn renderLocked(self: *Spinner) void {
    var buf: [frame_buf_bytes]u8 = undefined;
    const glyph = braille[self.frame % braille.len];
    const written = switch (self.state) {
        .idle => return,
        .thinking => std.fmt.bufPrint(
            &buf,
            "\r" ++ ansi.yellow ++ "{s}" ++ ansi.reset ++ " " ++ ansi.dim ++ "[agent: thinking]" ++ ansi.reset ++ clear_eol,
            .{glyph},
        ) catch return,
        .tool => |tool| blk: {
            const prefix: []const u8 = if (tool.manual) "" else "agent: ";
            const name = tool.name_buf[0..tool.name_len];
            const all_args = tool.args_buf[0..tool.args_len];
            // "<glyph> [<prefix><name> <args>]" — 5 fixed decoration cells
            // (glyph, two spaces, `[`, `]`) around prefix+name+args. `\r` and
            // ANSI escapes are zero-width, so they don't count toward wrap.
            const decoration_cells: usize = 5 + prefix.len + name.len;
            const cols: usize = Terminal.columns() orelse 80;
            // Reserve one extra cell so the line is strictly less than `cols`:
            // auto-wrap (DECAWM) terminals advance past a row that exactly fills
            // the width.
            const reserved = decoration_cells + ellipsis_cells + 1;
            const room: usize = if (cols > reserved) cols - reserved else 0;
            const cap = @min(max_args_cells, room);
            const cut = truncToCells(all_args, cap);
            const suffix: []const u8 = if (cut < all_args.len) ellipsis else "";
            break :blk std.fmt.bufPrint(
                &buf,
                "\r" ++ ansi.yellow ++ "{s}" ++ ansi.reset ++ " " ++ ansi.dim ++ "[{s}{s} {s}{s}]" ++ ansi.reset ++ clear_eol,
                .{ glyph, prefix, name, all_args[0..cut], suffix },
            ) catch return;
        },
    };
    if (written.len == self.last_render_len and std.mem.eql(u8, written, self.last_render_buf[0..self.last_render_len])) return;
    @memcpy(self.last_render_buf[0..written.len], written);
    self.last_render_len = written.len;
    _ = std.posix.write(std.posix.STDERR_FILENO, written) catch {};
}

/// Returns the byte length of `bytes` that fits in `max_cells` cells, rounded
/// down to a whole UTF-8 codepoint. Multi-cell glyphs (CJK, wide emoji) count
/// as 1 — args are typically ASCII, so the approximation is good enough.
fn truncToCells(bytes: []const u8, max_cells: usize) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and cells < max_cells) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        if (i + seq_len > bytes.len) break;
        i += seq_len;
        cells += 1;
    }
    return i;
}

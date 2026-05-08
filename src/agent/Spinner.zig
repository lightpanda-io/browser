const std = @import("std");
const ansi = @import("Terminal.zig").ansi;

const Self = @This();

const dots = [_][]const u8{ "   ", ".  ", ".. ", "..." };
const interval_ns: u64 = 350 * std.time.ns_per_ms;
/// Minimum dwell on a tool label so the user can read it. Slow tools exceed
/// this naturally; fast ones (getUrl, getCookies) get padded.
const min_tool_display_ns: u64 = 1500 * std.time.ns_per_ms;
const clear_eol = "\x1b[K";

const max_args_bytes: usize = 100;
const frame_buf_bytes: usize = 256;

const State = enum { idle, thinking, tool };

enabled: bool,

mu: std.Thread.Mutex = .{},
cv: std.Thread.Condition = .{},
state: State = .idle,
frame: u8 = 0,

tool_name_buf: [64]u8 = undefined,
tool_name_len: usize = 0,
tool_args_buf: [max_args_bytes]u8 = undefined,
tool_args_len: usize = 0,

tool_calls: u32 = 0,
turn_started_ns: i128 = 0,
tool_set_ns: i128 = 0,
/// The model has moved past the current tool back to thinking, but the
/// spinner is still showing the tool label until `min_tool_display_ns`
/// elapses. Cleared when the worker flips back to `.thinking`, or by a
/// fresh `setTool` that overrides the dwell.
still_thinking: bool = false,
/// Set by `markToolFailed` so the active tool label renders in red.
/// Cleared on the next `setTool`.
tool_failed: bool = false,

thread: ?std.Thread = null,
should_exit: bool = false,

last_render_buf: [frame_buf_bytes]u8 = undefined,
last_render_len: usize = 0,

pub fn init(is_repl: bool, stderr_is_tty: bool) Self {
    return .{ .enabled = is_repl and stderr_is_tty };
}

pub fn deinit(self: *Self) void {
    if (self.thread) |t| {
        self.mu.lock();
        self.should_exit = true;
        self.cv.signal();
        self.mu.unlock();
        t.join();
        self.thread = null;
    }
}

/// Begin a new agent turn. Spawns the worker thread on first call.
pub fn start(self: *Self) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    self.state = .thinking;
    self.frame = 0;
    self.tool_calls = 0;
    self.turn_started_ns = std.time.nanoTimestamp();
    self.still_thinking = false;
    self.tool_set_ns = 0;
    if (self.thread == null) {
        self.thread = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
    }
    self.cv.signal();
}

/// End an agent turn cleanly: clear the indicator, commit a one-line summary,
/// reset state. Called from a `defer` in the agent code so it always runs.
pub fn stop(self: *Self) void {
    if (!self.enabled) return;
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

/// End a turn with no commit (used on hard API errors, where the caller will
/// surface the error itself).
pub fn cancel(self: *Self) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state == .idle) return;
    _ = std.posix.write(std.posix.STDERR_FILENO, "\r" ++ clear_eol) catch {};
    self.state = .idle;
    self.last_render_len = 0;
}

/// Switch the indicator to "running tool <name> <args>". Counts toward the
/// turn's tool-call total. Args are truncated to `max_args_bytes`.
pub fn setTool(self: *Self, name: []const u8, args: []const u8) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    self.tool_calls += 1;
    self.tool_name_len = @min(name.len, self.tool_name_buf.len);
    @memcpy(self.tool_name_buf[0..self.tool_name_len], name[0..self.tool_name_len]);
    self.tool_args_len = @min(args.len, self.tool_args_buf.len);
    @memcpy(self.tool_args_buf[0..self.tool_args_len], args[0..self.tool_args_len]);
    self.state = .tool;
    self.still_thinking = false;
    self.tool_failed = false;
    self.tool_set_ns = std.time.nanoTimestamp();
    self.renderLocked();
    self.cv.signal();
}

/// Repaint the active tool label in red to flag a failed tool call. Visible
/// for the rest of the dwell window (`min_tool_display_ns`), then the
/// indicator returns to thinking like any other call.
pub fn markToolFailed(self: *Self) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state != .tool) return;
    self.tool_failed = true;
    self.renderLocked();
}

/// Request a transition back to the cycling "thinking" state. The worker
/// honors `min_tool_display_ns` — if the current tool label has not been
/// up long enough, the flip is deferred until it has.
pub fn setThinking(self: *Self) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state == .idle) return;
    self.still_thinking = true;
    self.cv.signal();
}

/// Print `text` (which should already include any newline) above the
/// indicator: clear current line, write text, leave indicator to repaint
/// itself on the next tick. Used by `Terminal.printToolResult` to surface
/// verbose result bodies and tool errors without interleaving with frames.
pub fn emitAbove(self: *Self, text: []const u8) bool {
    if (!self.enabled) return false;
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

fn workerLoop(self: *Self) void {
    self.mu.lock();
    defer self.mu.unlock();
    while (!self.should_exit) {
        while (!self.should_exit and self.state == .idle) self.cv.wait(&self.mu);
        if (self.should_exit) return;

        // Honor minimum tool-display time before reverting to thinking.
        if (self.state == .tool and self.still_thinking) {
            const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - self.tool_set_ns);
            if (elapsed_ns >= min_tool_display_ns) {
                self.state = .thinking;
                self.still_thinking = false;
                self.frame = 0;
            }
        }

        self.renderLocked();

        if (self.state == .thinking) {
            self.frame = (self.frame + 1) % @as(u8, @intCast(dots.len));
        }
        self.cv.timedWait(&self.mu, interval_ns) catch {};
    }
}

fn renderLocked(self: *Self) void {
    var buf: [frame_buf_bytes]u8 = undefined;
    const written = switch (self.state) {
        .idle => return,
        .thinking => std.fmt.bufPrint(
            &buf,
            "\r" ++ ansi.yellow ++ "●" ++ ansi.reset ++ " " ++ ansi.dim ++ "[agent: thinking{s}]" ++ ansi.reset ++ clear_eol,
            .{dots[self.frame % dots.len]},
        ) catch return,
        .tool => std.fmt.bufPrint(
            &buf,
            "\r{s}●" ++ ansi.reset ++ " " ++ ansi.dim ++ "[agent: {s} {s}]" ++ ansi.reset ++ clear_eol,
            .{
                if (self.tool_failed) ansi.red else ansi.green,
                self.tool_name_buf[0..self.tool_name_len],
                self.tool_args_buf[0..self.tool_args_len],
            },
        ) catch return,
    };
    if (written.len == self.last_render_len and std.mem.eql(u8, written, self.last_render_buf[0..self.last_render_len])) return;
    @memcpy(self.last_render_buf[0..written.len], written);
    self.last_render_len = written.len;
    _ = std.posix.write(std.posix.STDERR_FILENO, written) catch {};
}

const std = @import("std");
const lp = @import("lightpanda");
const log = lp.log;
const ansi = @import("Terminal.zig").ansi;

const Self = @This();

const dots = [_][]const u8{ "   ", ".  ", ".. ", "..." };
const braille = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const interval_ns: u64 = 100 * std.time.ns_per_ms;
/// Minimum dwell on a tool label so the user can read it. Slow tools exceed
/// this naturally; fast ones (getUrl, getCookies) get padded.
const min_tool_display_ns: u64 = 1500 * std.time.ns_per_ms;
const clear_eol = ansi.clear_eol;

const max_args_bytes: usize = 100;
const frame_buf_bytes: usize = 256;

const ToolState = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    args_buf: [max_args_bytes]u8 = undefined,
    args_len: usize = 0,
    /// Wall-clock at which `setTool` last fired; gates dwell-honoring.
    set_ns: i128 = 0,
    /// Worker should flip back to thinking once dwell elapses. Cleared by a
    /// fresh `setTool` (which overrides the dwell with a new label).
    dwell_pending: bool = false,
    /// Render the label in red — set by `markToolFailed`, cleared by next setTool.
    failed: bool = false,
    /// User-typed REPL commands drop the `agent:` framing since no agent
    /// is involved — it's lightpanda running the command directly.
    manual: bool = false,
};

const State = union(enum) {
    idle,
    thinking,
    tool: ToolState,
};

enabled: bool,

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
    self.ensureWorkerLocked();
    self.cv.signal();
}

fn ensureWorkerLocked(self: *Self) void {
    if (self.thread == null) {
        self.thread = std.Thread.spawn(.{}, workerLoop, .{self}) catch |err| blk: {
            log.warn(.app, "spinner thread spawn failed", .{ .err = @errorName(err) });
            self.enabled = false;
            self.state = .idle;
            self.last_render_len = 0;
            break :blk null;
        };
    }
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

/// End a turn with no commit. The caller is responsible for surfacing the
/// outcome — tool results, error messages, or summaries.
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
/// turn's tool-call total. Args are truncated to `max_args_bytes`. Called
/// without a preceding `start()` (state `.idle`) the label drops the `agent:`
/// prefix — that path is for user-typed REPL commands, not LLM tool calls.
pub fn setTool(self: *Self, name: []const u8, args: []const u8) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    const manual = self.state == .idle;
    self.tool_calls += 1;
    var tool: ToolState = .{ .set_ns = std.time.nanoTimestamp(), .manual = manual };
    tool.name_len = @min(name.len, tool.name_buf.len);
    @memcpy(tool.name_buf[0..tool.name_len], name[0..tool.name_len]);
    tool.args_len = @min(args.len, tool.args_buf.len);
    @memcpy(tool.args_buf[0..tool.args_len], args[0..tool.args_len]);
    self.frame = 0;
    self.state = .{ .tool = tool };
    // Manual paths skip `start()`, so spawn the worker on demand to drive
    // the braille animation.
    if (manual) self.ensureWorkerLocked();
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
    switch (self.state) {
        .tool => {
            self.state.tool.failed = true;
            self.renderLocked();
        },
        else => {},
    }
}

/// Request a transition back to the cycling "thinking" state. The worker
/// honors `min_tool_display_ns` — if the current tool label has not been
/// up long enough, the flip is deferred until it has.
pub fn setThinking(self: *Self) void {
    if (!self.enabled) return;
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .idle => return,
        .thinking => {},
        .tool => self.state.tool.dwell_pending = true,
    }
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
        switch (self.state) {
            .tool => {
                if (self.state.tool.dwell_pending) {
                    // Compare signed: a backward clock jump (NTP slew, suspend/resume)
                    // can make the delta negative; `@intCast` to u64 would panic.
                    const delta: i128 = std.time.nanoTimestamp() - self.state.tool.set_ns;
                    if (delta >= @as(i128, min_tool_display_ns)) {
                        self.state = .thinking;
                        self.frame = 0;
                    }
                }
            },
            else => {},
        }

        self.renderLocked();

        if (self.state == .thinking) {
            self.frame = (self.frame + 1) % @as(u8, @intCast(dots.len));
        } else if (std.meta.activeTag(self.state) == .tool and self.state.tool.manual) {
            self.frame = (self.frame + 1) % @as(u8, @intCast(braille.len));
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
        .tool => |tool| blk: {
            const color: []const u8 = if (tool.failed) ansi.red else if (tool.manual) ansi.yellow else ansi.green;
            const glyph: []const u8 = if (tool.manual) braille[self.frame % braille.len] else "●";
            const prefix: []const u8 = if (tool.manual) "" else "agent: ";
            break :blk std.fmt.bufPrint(
                &buf,
                "\r{s}{s}" ++ ansi.reset ++ " " ++ ansi.dim ++ "[{s}{s} {s}]" ++ ansi.reset ++ clear_eol,
                .{ color, glyph, prefix, tool.name_buf[0..tool.name_len], tool.args_buf[0..tool.args_len] },
            ) catch return;
        },
    };
    if (written.len == self.last_render_len and std.mem.eql(u8, written, self.last_render_buf[0..self.last_render_len])) return;
    @memcpy(self.last_render_buf[0..written.len], written);
    self.last_render_len = written.len;
    _ = std.posix.write(std.posix.STDERR_FILENO, written) catch {};
}

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("js/js.zig");
const Browser = @import("Browser.zig");
const Session = @import("Session.zig");
const HttpClient = @import("HttpClient.zig");

const Node = @import("webapi/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");

const log = lp.log;

const Runner = @This();

session: *Session,
browser: *Browser,
http_client: *HttpClient,

pub const Opts = struct {};

pub fn init(session: *Session, _: Opts) Runner {
    return .{
        .session = session,
        .browser = session.browser,
        .http_client = &session.browser.http_client,
    };
}

pub const WaitCondition = struct {
    frame_id: u32,
    until: lp.Config.WaitUntil = .done,
    status: Status = .pending,

    const Status = union(enum) {
        pending,
        complete,
        err: anyerror,
    };
};

const WaitForFrameOpts = struct {
    until: lp.Config.WaitUntil = .done,
};
pub fn waitForFrame(self: *Runner, frame_id: u32, timeout_ms: u32, opts: WaitForFrameOpts) !void {
    const condition = WaitCondition{ .frame_id = frame_id, .until = opts.until };
    var conditions = [_]WaitCondition{condition};
    _ = try self._wait(false, timeout_ms, &conditions);
    try firstConditionError(&conditions);
}

pub fn waitForFrameCDP(self: *Runner, frame_id: u32, timeout_ms: u32, until: lp.Config.WaitUntil) !void {
    const condition = WaitCondition{ .frame_id = frame_id, .until = until };
    var conditions = [_]WaitCondition{condition};
    // Unlike waitForFrame, we deliberately don't surface a per-frame error here.
    // The frame we're waiting on can legitimately disappear mid-wait.
    _ = try self._wait(true, timeout_ms, &conditions);
}

// Helper to wait for all currently loaded frames
pub fn waitForAll(self: *Runner, timeout_ms: u32, opts: WaitForFrameOpts) !void {
    const session = self.session;
    const arena = try session.getArena(.tiny, "Runner.waitForAll");
    defer session.releaseArena(arena);

    var pages_to_wait: usize = 0;
    for (session.pages.items) |page| {
        if (page.replacement == null) {
            pages_to_wait += 1;
        }
    }

    const conditions = try arena.alloc(WaitCondition, pages_to_wait);
    var i: usize = 0;
    for (session.pages.items) |page| {
        if (page.replacement == null) {
            conditions[i] = .{ .frame_id = page.frame._frame_id, .until = opts.until };
            i += 1;
        }
    }
    _ = try self._wait(false, timeout_ms, conditions);
    try firstConditionError(conditions);
}

pub fn wait(self: *Runner, timeout_ms: u32, conditions: []WaitCondition) !void {
    try self._wait(false, timeout_ms, conditions);
}

pub const WaitResult = enum { completed, timeout };
pub fn waitResult(self: *Runner, timeout_ms: u32, conditions: []WaitCondition) !WaitResult {
    return self._wait(false, timeout_ms, conditions);
}

// Wait until either a parse-state / load goal is reached or `opts.ms`
// elapses. Returns as soon as _tick reports .done.
fn _wait(self: *Runner, comptime is_cdp: bool, timeout_ms: u32, conditions: []WaitCondition) !WaitResult {
    const browser = self.browser;

    var timer = try std.time.Timer.start();

    // Periodic V8 GC hint during long waits. V8 is otherwise only nudged on
    // session/page teardown (Browser.zig, Page.zig), so a page that stays
    // alive for seconds while running heavy JS accumulates wrappers and
    // external-ref'd Zig allocations V8 has no reason to drop. `.moderate`
    // speeds up incremental GC without stalling the tick.
    const gc_hint_period_ns: u64 = std.time.ns_per_s;
    var gc_hint_timer = std.time.Timer.start() catch unreachable;

    while (true) {
        // The CDP path can have its session closed mid-wait: a command
        // dispatched by the previous tick (e.g. disposeBrowserContext) can call
        // browser.closeSession (see the `browser` field comment). So re-derive
        // the live session each pass there and end the wait once it's gone.
        // Non-CDP callers hold a stable session, so they skip the check.
        const session = if (comptime is_cdp)
            (if (browser.session) |*s| s else return .completed)
        else
            self.session;

        // Cooperative cancellation. Set by the agent so SIGINT can break
        // out of a long wait without the user sitting through the timeout.
        if (session.isCancelled()) {
            return error.Cancelled;
        }

        if (gc_hint_timer.read() >= gc_hint_period_ns) {
            gc_hint_timer.reset();
            browser.env.memoryPressureNotification(.moderate);
        }
        session.processDestroyQueues();

        const tick_result = self._tick(is_cdp, 200, conditions) catch |err| {
            switch (err) {
                error.JsError => {}, // already logged (with hopefully more context)
                error.ClientDisconnected => {}, // CDP layer already logged this
                else => log.err(.browser, "session wait", .{ .err = err }),
            }
            return err;
        };

        const next_ms = switch (tick_result) {
            .ok => |next_ms| next_ms,
            .done => done_blk: {
                if (comptime is_cdp == false) {
                    return .completed;
                }

                // is_cdp keeps the loop alive past .done so the worker
                // can observe CDP commands. We have nothing useful to do here
                // but we can ask the http_client to wait for CDP messages.
                const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
                if (elapsed >= timeout_ms) {
                    return .timeout;
                }
                try self.http_client.tick(@min(timeout_ms - elapsed, 200), .all);
                break :done_blk 0;
            },
        };

        const ms_elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (ms_elapsed >= timeout_ms) {
            return .timeout;
        }
        if (next_ms > 0) {
            std.Thread.sleep(std.time.ns_per_ms * next_ms);
        }
    }
}

pub const TickResult = union(enum) {
    done,
    ok: u32,
};
pub fn tickForFrame(self: *Runner, frame_id: u32, timeout_ms: u32, opts: WaitForFrameOpts) !TickResult {
    const condition = WaitCondition{ .frame_id = frame_id, .until = opts.until };
    var conditions = [_]WaitCondition{condition};
    const result = try self.tick(timeout_ms, &conditions);
    try firstConditionError(&conditions);
    return result;
}
pub fn tick(self: *Runner, timeout_ms: u32, conditions: []WaitCondition) !TickResult {
    return self._tick(false, timeout_ms, conditions);
}

fn _tick(self: *Runner, comptime is_cdp: bool, timeout_ms: u32, conditions: []WaitCondition) !TickResult {
    const session = self.session;
    const browser = self.browser;
    const http_client = self.http_client;

    // Drain queued navigations across every live page (one page per call)
    // A navigation can swap a frame pointer or the page set,
    // so restart the tick to re-resolve cleanly.
    if (try session.processQueuedNavigation()) {
        return .{ .ok = 0 };
    }

    if (hasRunnablePage(session)) {
        try browser.runMacrotasks();
    }

    const http_active = http_client.http_active;
    const http_next_tick = http_client.next_tick_count;
    const total_http_activity = http_active + http_next_tick + http_client.interception_layer.intercepted;
    const total_network_activity = total_http_activity + http_client.ws_active;

    const ms_to_next_macrotask = browser.msToNextMacrotask();
    const network_idle = total_network_activity == 0 and http_client.queue.first == null and http_client.ready_queue.first == null;
    const is_done = ms_to_next_macrotask == null and network_idle;

    // _we_ have nothing to run, but v8 is working on background tasks. We'll
    // wait for them. Don't do this for CDP, since new CDP messages can always
    // come in at any time.
    if ((comptime is_cdp) == false and network_idle and browser.hasBackgroundTasks()) {
        browser.waitForBackgroundTasks();
        return .{ .ok = 0 };
    }

    var want_http_tick = false;

    for (conditions) |*condition| {
        if (condition.status != .pending) {
            // this condition is at a terminal state
            continue;
        }

        const page = session.pendingOrLivePage(condition.frame_id) orelse {
            condition.status = .{ .err = error.FrameNotFound };
            continue;
        };

        const frame = &page.frame;
        switch (frame._parse_state) {
            .err => |err| {
                frame._parse_state = .{ .raw_done = @errorName(err) };
                condition.status = .{ .err = err };
            },
            .raw_done => {
                condition.status = .complete;
            },
            .pre, .raw, .text, .image, .download => {
                if (total_network_activity == 0) {
                    condition.status = .complete;
                } else {
                    want_http_tick = true;
                }
            },
            .html, .complete => {
                frame.checkIdleNotifications(total_http_activity);

                const met = switch (condition.until) {
                    .done => is_done,
                    .domcontentloaded => frame._load_state == .load or frame._load_state == .complete,
                    .load => frame._load_state == .complete,
                    .networkidle => frame._notified_network_idle == .done,
                    .networkalmostidle => frame._notified_network_almost_idle == .done,
                };

                // `met` resolves the condition. Otherwise, as long as there's
                // still work in flight (network or pending macrotasks), keep
                // ticking. `is_done` means the page went fully idle without
                // reaching the goal — there's nothing left to wait on, so
                // resolve rather than spin forever.
                if (met or is_done) {
                    condition.status = .complete;
                } else {
                    want_http_tick = true;
                }
            },
        }
    }

    if ((comptime is_cdp) or want_http_tick) {
        var ms_to_wait = @min(timeout_ms, ms_to_next_macrotask orelse 200);
        if (browser.hasBackgroundTasks()) {
            // background work will queue more to do soon — don't block long
            // for a client message; loop back and run macrotasks instead.
            ms_to_wait = @min(ms_to_wait, 10);
        }
        try http_client.tick(@intCast(ms_to_wait), .all);
        return .{ .ok = 0 };
    }

    return .done;
}

pub fn waitForSelector(self: *Runner, frame_id: u32, input: [:0]const u8, timeout_ms: u32) !*Node.Element {
    const session = self.session;
    const arena = try session.getArena(.small, "Runner.waitForSelector");
    defer session.releaseArena(arena);

    var timer = try std.time.Timer.start();
    const selector = try Selector.parseLeaky(arena, input);

    while (true) {
        if (session.isCancelled()) {
            return error.Cancelled;
        }

        const page = session.pendingOrLivePage(frame_id) orelse {
            return error.FrameNotFound;
        };
        const frame = &page.frame;

        if (try Selector.query(selector, frame.document.asNode(), frame)) |el| {
            return el;
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) {
            return error.Timeout;
        }
        switch (try self.tickForFrame(frame_id, timeout_ms - elapsed, .{ .until = .done })) {
            // Idle: poll so `timeout_ms` means "wait up to N ms", not "fail now".
            .done => std.Thread.sleep(std.time.ns_per_ms * @as(u64, @min(timeout_ms - elapsed, 50))),
            .ok => |recommended_sleep_ms| {
                if (recommended_sleep_ms > 0) {
                    std.Thread.sleep(std.time.ns_per_ms * recommended_sleep_ms);
                }
            },
        }
    }
}

pub fn waitForScript(self: *Runner, frame_id: u32, src: [:0]const u8, timeout_ms: u32) !void {
    const session = self.session;
    var timer = try std.time.Timer.start();

    // Compile the script once and re-use the compiled form. A tick can create a
    // new context (an internal navigation), so we keep an unbound script (one
    // not bound to a particular context) and bind it to the current context on
    // each tick. Compilation is context-independent, so we can do it up front
    // in whatever context the frame currently has.
    var compiled: js.Script.Unbound.Global = blk: {
        const page = session.pendingOrLivePage(frame_id) orelse {
            return error.FrameNotFound;
        };
        const frame = &page.frame;

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const s = ls.local.compile(src, "wait_script") catch |err| {
            const caught = try_catch.caughtOrError(frame.local_arena, err);
            log.err(.app, "wait script error", .{ .err = caught });
            return error.ScriptError;
        };
        break :blk s.getUnboundScript().persist(ls.local.isolate);
    };
    defer compiled.deinit();

    while (true) {
        if (session.isCancelled()) {
            return error.Cancelled;
        }

        const page = session.pendingOrLivePage(frame_id) orelse {
            return error.FrameNotFound;
        };
        const frame = &page.frame;

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const script = compiled.get(ls.local.isolate).bindToCurrentContext(&ls.local);
        const value = script.run() catch |err| {
            const caught = try_catch.caughtOrError(frame.local_arena, err);
            log.err(.app, "wait script error", .{ .err = caught });
            return error.ScriptError;
        };

        if (value.toBool()) {
            return;
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) {
            return error.Timeout;
        }
        switch (try self.tickForFrame(frame_id, timeout_ms - elapsed, .{ .until = .done })) {
            // Idle: poll so `timeout_ms` means "wait up to N ms", not "fail now".
            .done => std.Thread.sleep(std.time.ns_per_ms * @as(u64, @min(timeout_ms - elapsed, 50))),
            .ok => |recommended_sleep_ms| {
                if (recommended_sleep_ms > 0) {
                    std.Thread.sleep(std.time.ns_per_ms * recommended_sleep_ms);
                }
            },
        }
    }
}

fn firstConditionError(conditions: []const WaitCondition) !void {
    for (conditions) |condition| {
        switch (condition.status) {
            .err => |err| return err,
            else => {},
        }
    }
}

fn hasRunnablePage(session: *Session) bool {
    for (session.pages.items) |page| {
        switch (page.frame._parse_state) {
            .html, .complete => return true,
            else => {},
        }
    }
    return false;
}

const testing = @import("../testing.zig");
test "Runner: waitForSelector timeout" {
    const page = try testing.pageTest("runner/runner1.html", .{});
    defer page.close();

    var runner = page.session.runner(.{});
    try testing.expectError(error.Timeout, runner.waitForSelector(page.frame_id, "#nope", 10));
}

test "Runner: waitForSelector" {
    defer testing.reset();
    const page = try testing.pageTest("runner/runner1.html", .{});

    var runner = page.session.runner(.{});
    const el = try runner.waitForSelector(page.frame_id, "#sel1", 10);
    try testing.expectEqual("selector-1-content", try el.asNode().getTextContentAlloc(testing.arena_allocator));
}

test "Runner: waitForScript timeout" {
    const page = try testing.pageTest("runner/runner1.html", .{});
    defer page.close();

    var runner = page.session.runner(.{});
    try testing.expectError(error.Timeout, runner.waitForScript(page.frame_id, "document.querySelector('#nope')", 10));
}

test "Runner: waitForScript" {
    const page = try testing.pageTest("runner/runner1.html", .{});
    defer page.close();

    var runner = page.session.runner(.{});
    try runner.waitForScript(page.frame_id, "document.querySelector('#sel1')", 10);
}

test "Runner: networkidle notifies child frames" {
    const page = try testing.pageTest("runner/iframe_idle.html", .{});
    defer page.close();

    var runner = page.session.runner(.{});
    const frame = page.frame().?;
    try testing.expectEqual(2, frame.child_frames.items.len);

    // A `.networkidle` wait resolves via `is_done` once the page is fully
    // idle, which can happen before the 500ms idle-notification hold. Keep
    // ticking (like the CDP serve loop does) until the notifications fire.
    var attempts: usize = 0;
    while (frame._notified_network_idle != .done and attempts < 50) : (attempts += 1) {
        _ = try runner.tickForFrame(page.frame_id, 20, .{ .until = .networkidle });
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }

    try testing.expectEqual(true, frame._notified_network_idle == .done);
    for (frame.child_frames.items) |child| {
        try testing.expectEqual(true, child._notified_network_almost_idle == .done);
        try testing.expectEqual(true, child._notified_network_idle == .done);
    }
}

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
const builtin = @import("builtin");

const js = @import("js/js.zig");
const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const HttpClient = @import("HttpClient.zig");

const Node = @import("webapi/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

const Runner = @This();

frame: *Frame,
session: *Session,
http_client: *HttpClient,

pub const Opts = struct {};

pub fn init(session: *Session, _: Opts) !Runner {
    const frame = session.currentFrame() orelse return error.NoPage;

    return .{
        .frame = frame,
        .session = session,
        .http_client = &session.browser.http_client,
    };
}

pub const WaitOpts = struct {
    ms: u32,
    until: lp.Config.WaitUntil = .done,
};

pub const WaitResult = enum { completed, timeout };

pub fn wait(self: *Runner, opts: WaitOpts) !void {
    _ = try self._wait(false, opts);
}

pub fn waitCDP(self: *Runner, opts: WaitOpts) !void {
    _ = try self._wait(true, opts);
}

// `wait` that surfaces whether the goal was reached or the timeout fired.
pub fn waitResult(self: *Runner, opts: WaitOpts) !WaitResult {
    return self._wait(false, opts);
}

// Wait until either a parse-state / load goal is reached or `opts.ms`
// elapses. Returns as soon as _tick reports .done.
fn _wait(self: *Runner, comptime is_cdp: bool, opts: WaitOpts) !WaitResult {
    const session = self.session;
    const browser = session.browser;

    var timer = try std.time.Timer.start();

    const tick_opts = TickOpts{
        .ms = 200,
        .until = opts.until,
    };

    // Periodic V8 GC hint during long waits. V8 is otherwise only nudged on
    // session/page teardown (Browser.zig, Page.zig), so a page that stays
    // alive for seconds while running heavy JS accumulates wrappers and
    // external-ref'd Zig allocations V8 has no reason to drop. `.moderate`
    // speeds up incremental GC without stalling the tick.
    const gc_hint_period_ns: u64 = std.time.ns_per_s;
    var gc_hint_timer = std.time.Timer.start() catch unreachable;

    while (true) {
        // Cooperative cancellation. Set by the agent so SIGINT can break
        // out of a long wait without the user sitting through the timeout.
        if (session.isCancelled()) return error.Cancelled;

        if (gc_hint_timer.read() >= gc_hint_period_ns) {
            gc_hint_timer.reset();
            browser.env.memoryPressureNotification(.moderate);
        }
        session.processDestroyQueues();

        const tick_result = self._tick(is_cdp, tick_opts) catch |err| {
            switch (err) {
                error.JsError => {}, // already logged (with hopefully more context)
                error.ClientDisconnected => {}, // CDP layer already logged this
                else => log.err(.browser, "session wait", .{
                    .err = err,
                    .url = self.frame.url,
                }),
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
                if (elapsed >= opts.ms) {
                    return .timeout;
                }
                try self.http_client.tick(@min(opts.ms - elapsed, 200), .all);
                break :done_blk 0;
            },
        };

        const ms_elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (ms_elapsed >= opts.ms) {
            return .timeout;
        }
        if (next_ms > 0) {
            std.Thread.sleep(std.time.ns_per_ms * next_ms);
        }
    }
}

pub const TickOpts = struct {
    ms: u32,
    until: lp.Config.WaitUntil = .done,
};

pub const TickResult = union(enum) {
    done,
    ok: u32,
};
pub fn tick(self: *Runner, opts: TickOpts) !TickResult {
    return self._tick(false, opts);
}

fn _tick(self: *Runner, comptime is_cdp: bool, opts: TickOpts) !TickResult {
    // Refresh self.frame from session. In case of pending page, we want to
    // take its state while loading. If we use only the current frame, we will
    // return a .done result immediately.
    self.frame = self.session.pendingOrCurrentFrame() orelse return .done;
    const frame = self.frame;
    const http_client = self.http_client;

    switch (frame._parse_state) {
        .pre, .raw, .text, .image, .download => {
            // The main frame hasn't started/finished navigating.
            // There's no JS to run, and no reason to run the scheduler
            // — unless we're the CDP worker, in which case we want
            // http_client.tick to drain the inbox.
            if (http_client.http_active == 0 and http_client.next_tick_count == 0 and (comptime is_cdp) == false) {
                // haven't started navigating, I guess.
                return .done;
            }
            try http_client.tick(@intCast(opts.ms), .all);
            return .{ .ok = 0 };
        },
        .html, .complete => {
            const session = self.session;
            if (session.currentPage()) |page| {
                if (page.queued_navigation.items.len != 0) {
                    try session.processQueuedNavigation();
                    self.frame = session.currentFrame().?; // might have changed
                    return .{ .ok = 0 };
                }
            }
            const browser = session.browser;

            // The HTML page was parsed. We now either have JS scripts to
            // download, or scheduled tasks to execute, or both.

            // scheduler.run could trigger new http transfers, so do not
            // store http_client.http_active BEFORE this call and then use
            // it AFTER.
            try browser.runMacrotasks();

            const http_active = http_client.http_active;
            const http_next_tick = http_client.next_tick_count;
            const total_network_activity = http_active + http_next_tick + http_client.interception_layer.intercepted;
            if (frame._notified_network_almost_idle.check(total_network_activity <= 2)) {
                frame.notifyNetworkAlmostIdle();
            }
            if (frame._notified_network_idle.check(total_network_activity == 0)) {
                frame.notifyNetworkIdle();
            }

            switch (opts.until) {
                .done => {},
                .domcontentloaded => if (frame._load_state == .load or frame._load_state == .complete) {
                    return .done;
                },
                .load => if (frame._load_state == .complete) {
                    return .done;
                },
                .networkidle => if (frame._notified_network_idle == .done) {
                    return .done;
                },
                .networkalmostidle => if (frame._notified_network_almost_idle == .done) {
                    return .done;
                },
            }

            if (http_active == 0 and http_next_tick == 0 and http_client.ws_active == 0 and http_client.queue.first == null and http_client.ready_queue.first == null and (comptime is_cdp) == false) {
                // ready_queue is also part of the check: makeRequest now
                // wraps its handles.perform() in a performing=true window,
                // and any synchronous libcurl callback that ends up
                // calling trackConn during that window (e.g. JS creating
                // a WebSocket) will append to ready_queue. Without this
                // check we could observe it non-empty after
                // http_client.tick returns.
                //
                // intercepted is only non-zero in serve mode, and
                // serve mode implies cdp_client != null — so if we got
                // here, intercepted == 0.
                if (comptime IS_DEBUG) {
                    std.debug.assert(http_client.interception_layer.intercepted == 0);
                }

                if (browser.hasBackgroundTasks()) {
                    // _we_ have nothing to run, but v8 is working on
                    // background tasks. We'll wait for them.
                    browser.waitForBackgroundTasks();
                }

                // We never advertise a wait time of more than 20, there can
                // always be new background tasks to run.
                if (browser.msToNextMacrotask()) |ms_to_next_task| {
                    return .{ .ok = @min(ms_to_next_task, 20) };
                }
                return .done;
            }

            // We're here because we either have active HTTP
            // connections, or there's a CDP client whose inbox we have
            // to drain via http_client.tick. We should continue to run
            // tasks, so we minimize how long we'll poll for network I/O.
            var ms_to_wait = @min(opts.ms, browser.msToNextMacrotask() orelse 200);
            if (ms_to_wait > 10 and browser.hasBackgroundTasks()) {
                // if we have background tasks, we don't want to wait too
                // long for a message from the client. We want to go back
                // to the top of the loop and run macrotasks.
                ms_to_wait = 10;
            }
            try http_client.tick(@intCast(@min(opts.ms, ms_to_wait)), .all);
            return .{ .ok = 0 };
        },
        .err => |err| {
            frame._parse_state = .{ .raw_done = @errorName(err) };
            return err;
        },
        .raw_done => {
            if (comptime is_cdp) {
                try http_client.tick(@intCast(opts.ms), .all);
                return .{ .ok = 0 };
            }
            return .done;
        },
    }
}

pub fn waitForSelector(self: *Runner, selector: [:0]const u8, timeout_ms: u32) !*Node.Element {
    const arena = try self.session.getArena(.small, "Runner.waitForSelector");
    defer self.session.releaseArena(arena);

    var timer = try std.time.Timer.start();
    const parsed_selector = try Selector.parseLeaky(arena, selector);

    while (true) {
        if (self.session.isCancelled()) return error.Cancelled;
        // self.frame can change between ticks
        const frame = self.frame;
        if (try parsed_selector.query(frame.document.asNode(), frame)) |el| {
            return el;
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) {
            return error.Timeout;
        }
        switch (try self.tick(.{ .ms = timeout_ms - elapsed })) {
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

pub fn waitForScript(runner: *Runner, src: [:0]const u8, timeout_ms: u32) !void {
    var timer = try std.time.Timer.start();

    // Compile the script once and re-use the compiled form. A tick can create a
    // new context (an internal navigation), so we keep an unbound script (one
    // not bound to a particular context) and bind it to the current context on
    // each tick. Compilation is context-independent, so we can do it up front
    // in whatever context the frame currently has.
    var compiled: js.Script.Unbound.Global = blk: {
        var ls: js.Local.Scope = undefined;
        runner.frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const s = ls.local.compile(src, "wait_script") catch |err| {
            const caught = try_catch.caughtOrError(runner.frame.call_arena, err);
            log.err(.app, "wait script error", .{ .err = caught });
            return error.ScriptError;
        };
        break :blk s.getUnboundScript().persist(ls.local.isolate);
    };
    defer compiled.deinit();

    while (true) {
        if (runner.session.isCancelled()) return error.Cancelled;
        const frame = runner.frame;

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const script = compiled.get(ls.local.isolate).bindToCurrentContext(&ls.local);
        const value = script.run() catch |err| {
            const caught = try_catch.caughtOrError(frame.call_arena, err);
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
        switch (try runner.tick(.{ .ms = timeout_ms - elapsed })) {
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

const testing = @import("../testing.zig");
test "Runner: no page" {
    try testing.expectError(error.NoPage, Runner.init(testing.test_session, .{}));
}

test "Runner: waitForSelector timeout" {
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try testing.expectError(error.Timeout, runner.waitForSelector("#nope", 10));
}

test "Runner: waitForSelector" {
    defer testing.reset();
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    const el = try runner.waitForSelector("#sel1", 10);
    try testing.expectEqual("selector-1-content", try el.asNode().getTextContentAlloc(testing.arena_allocator));
}

test "Runner: waitForScript timeout" {
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try testing.expectError(error.Timeout, runner.waitForScript("document.querySelector('#nope')", 10));
}

test "Runner: waitForScript" {
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try runner.waitForScript("document.querySelector('#sel1')", 10);
}

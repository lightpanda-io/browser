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

// Shared bookkeeping for setTimeout / setInterval (and Window-only
// requestAnimationFrame / requestIdleCallback). Both Window
// and WorkerGlobalScope embed a Timers and forward their JS-bridged
// methods through `schedule` / `clear`.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const log = lp.log;

const CLAMP_MS = 4;
const CLAMP_NESTING = 5;

// Once we hit this depth, tasks are scheduled with blocks_done = false. This
// prevents, for example, a setTimeout that sets itself, from blocking the Runner
// from considering the page "done" forever (more commonly seen with requestAnimationFrame)
const BLOCKING_NESTING = 10;

// Every pending timeout, interval, animation frame and idle callback. Past
// the cap setTimeout throws, which no browser does; keep it a backstop for
// runaway pages, not a budget (a paginated storefront listing holds ~2.7k).
const MAX_CALLBACKS = 8192;

// lower limit for repeating timers since they never clean up
// (unless clearInterval is called)
const MAX_REPEATING = 2048;

const Timers = @This();

_timer_id: u30 = 0,
_repeating: u32 = 0, // # of repeating timers we have
_callbacks: CallbackHashMap = .{},

// We keep the depth of the timers (a setTimeout calling a setTimeout). When
// the timer depth reaches CLAMP_NESTING, the minimum timeout is 4ms. This is
// per-spec and it's necessary to prevent some sites from virtually breaking
// because they repeatedly do heavy work in endlessly looping setTimeout with
// a short timeout (often of 0ms).
_nesting_level: u8 = 0,

const Key = u32;
const CallbackHashMap = std.HashMapUnmanaged(
    Key,
    *ScheduleCallback,
    struct {
        pub fn hash(_: @This(), key: Key) Key {
            return std.hash.int(key);
        }

        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return std.meta.eql(a, b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub const Mode = enum {
    idle,
    normal,
    animation_frame,
};

const ScheduleOpts = struct {
    repeat: bool,
    params: []js.Value.Global,
    name: []const u8,
    blocks_done: bool = true,
    mode: Mode = .normal,
};

// setTimeout/setInterval take the delay as a WebIDL long: wrapped to 32 bits, negatives clamped to 0.
pub fn delayFromJs(delay_ms: ?i32) u32 {
    return @intCast(@max(delay_ms orelse 0, 0));
}

pub fn schedule(
    self: *Timers,
    exec: *js.Execution,
    cb: js.Function.Global,
    delay_ms: u32,
    opts: ScheduleOpts,
) !u32 {
    if (self._callbacks.count() >= MAX_CALLBACKS) {
        return error.TooManyTimeout;
    }
    if (opts.repeat and self._repeating >= MAX_REPEATING) {
        return error.TooManyTimeout;
    }

    const arena = try exec.getArena(.tiny, "Timers.schedule");
    errdefer arena.release();

    const timer_id = self._timer_id +% 1;
    self._timer_id = timer_id;

    const nesting = @min(self._nesting_level + 1, BLOCKING_NESTING + 1);
    const delay = if (nesting > CLAMP_NESTING and delay_ms < CLAMP_MS) CLAMP_MS else delay_ms;

    var persisted_params: []js.Value.Global = &.{};
    if (opts.params.len > 0) {
        persisted_params = try arena.dupe(js.Value.Global, opts.params);
    }

    const gop = try self._callbacks.getOrPut(exec.arena, timer_id);
    if (gop.found_existing) {
        // 2^31 would have to wrap for this to happen.
        return error.TooManyTimeout;
    }
    errdefer _ = self._callbacks.remove(timer_id);

    const callback = try arena.create(ScheduleCallback);
    callback.* = .{
        .cb = cb,
        .exec = exec,
        .timers = self,
        .arena = arena,
        .mode = opts.mode,
        .name = opts.name,
        .nesting = nesting,
        .timer_id = timer_id,
        .params = persisted_params,
        .repeat_ms = if (opts.repeat) if (delay == 0) 1 else delay else null,
    };
    gop.value_ptr.* = callback;

    try exec.js.scheduler.add(callback, ScheduleCallback.run, delay, .{
        .name = opts.name,
        .blocks_done = opts.blocks_done and nesting <= BLOCKING_NESTING,
        .finalizer = ScheduleCallback.cancelled,
    });

    if (opts.repeat) {
        self._repeating += 1;
    }
    return timer_id;
}

pub fn clear(self: *Timers, id: u32) void {
    var sc = self._callbacks.fetchRemove(id) orelse return;
    if (sc.value.repeat_ms != null) {
        self._repeating -= 1;
    }
    sc.value.removed = true;
}

// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#dom-settimeout
// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#timerhandler
// TimerHandler = Function or DOMString. Anything that isn't callable is
// converted to a string (WebIDL union conversion), so `setTimeout(undefined)`
// compiles the script "undefined". The string is compiled into an anonymous
// function body, e.g. `setTimeout("foo()", 100)`.
pub const LegacyHandler = union(enum) {
    function: js.Function.Global,
    string: js.Value,

    pub fn resolve(handler: LegacyHandler, exec: *js.Execution) !js.Function.Global {
        switch (handler) {
            .function => |fun| return fun,
            .string => |value| {
                // Value.toString() uses a Symbol's description; ToString throws.
                if (value.isSymbol()) {
                    return error.InvalidArgument;
                }
                const fun = try exec.js.local.?.compileFunction(try value.toString(), &.{}, &.{});
                return fun.persist();
            },
        }
    }
};

const ScheduleCallback = struct {
    // for debugging
    name: []const u8,

    // Timers._callbacks key
    timer_id: u31,

    // delay, in ms, to repeat. When null, removed after first invocation.
    repeat_ms: ?u32,

    // The nesting of this task. When it executes, this nesting will become
    // the Timer's _nesting_level so that any new timers will become nesting + 1
    nesting: u8,

    cb: js.Function.Global,

    mode: Mode,
    exec: *js.Execution,
    timers: *Timers,
    arena: *lp.Arena,
    removed: bool = false,
    params: []const js.Value.Global,

    fn cancelled(ptr: *anyopaque) void {
        var self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinit(self: *ScheduleCallback) void {
        self.cb.release();
        for (self.params) |param| {
            param.release();
        }
        self.arena.release();
    }

    // An exception the callback doesn't catch is reported to the global, so
    // window's "error" event and onerror see it — the "report an exception"
    // step of the timer initialization steps and of running animation frame
    // and idle callbacks.
    fn invoke(self: *ScheduleCallback, local: *const js.Local, args: anytype, comptime context: []const u8) void {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        local.toLocal(self.cb).callRethrow(void, args) catch |err| {
            if (err == error.JsException or err == error.TryCatchRethrow) {
                if (try_catch.exceptionValue()) |exc| {
                    // reportError also counts the error on the page.
                    self.exec.reportError(exc) catch |report_err| {
                        log.debug(.js, context ++ " report error", .{ .name = self.name, .err = report_err });
                    };
                    return;
                }
            }
            self.exec.page.recordJsError(err);
            log.debug(.js, context, .{ .name = self.name, .err = err });
        };
    }

    fn run(ptr: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        if (self.removed) {
            self.deinit();
            return null;
        }

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const timers = self.timers;
        const prev_nesting = timers._nesting_level;
        timers._nesting_level = self.nesting;
        defer timers._nesting_level = prev_nesting;

        switch (self.mode) {
            .idle => {
                const IdleDeadline = @import("IdleDeadline.zig");
                self.invoke(&ls.local, .{IdleDeadline{}}, "idleCallback");
            },
            .animation_frame => {
                const now = switch (self.exec.js.global) {
                    .frame => |frame| frame.window._performance.now(),
                    .worker => |worker| worker._performance.now(),
                };
                self.invoke(&ls.local, .{now}, "RAF");
            },
            .normal => self.invoke(&ls.local, self.params, "timer"),
        }
        ls.local.runMicrotasks();

        if (self.repeat_ms) |ms| {
            // each repeat re-enters the timer initialization steps, so the
            // nesting level keeps growing and sub-4ms intervals get clamped.
            self.nesting = @min(self.nesting + 1, BLOCKING_NESTING + 1);
            if (self.nesting > CLAMP_NESTING and ms < CLAMP_MS) {
                return CLAMP_MS;
            }
            return ms;
        }
        defer self.deinit();
        _ = self.timers._callbacks.remove(self.timer_id);
        return null;
    }
};

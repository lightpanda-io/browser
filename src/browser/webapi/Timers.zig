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
// setImmediate / requestAnimationFrame / requestIdleCallback). Both Window
// and WorkerGlobalScope embed a Timers and forward their JS-bridged
// methods through `schedule` / `clear`.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const Timers = @This();

_timer_id: u30 = 0,
_callbacks: std.AutoHashMapUnmanaged(u32, *ScheduleCallback) = .{},

pub const Mode = enum {
    idle,
    normal,
    animation_frame,
};

pub const ScheduleOpts = struct {
    repeat: bool,
    params: []js.Value.Temp,
    name: []const u8,
    low_priority: bool = false,
    mode: Mode = .normal,
};

pub fn schedule(
    self: *Timers,
    exec: *js.Execution,
    cb: js.Function.Temp,
    delay_ms: u32,
    opts: ScheduleOpts,
) !u32 {
    if (self._callbacks.count() > 512) {
        // these are active
        return error.TooManyTimeout;
    }

    const arena = try exec.getArena(.tiny, "Timers.schedule");
    errdefer exec.releaseArena(arena);

    const timer_id = self._timer_id +% 1;
    self._timer_id = timer_id;

    var persisted_params: []js.Value.Temp = &.{};
    if (opts.params.len > 0) {
        persisted_params = try arena.dupe(js.Value.Temp, opts.params);
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
        .timer_id = timer_id,
        .params = persisted_params,
        .repeat_ms = if (opts.repeat) if (delay_ms == 0) 1 else delay_ms else null,
    };
    gop.value_ptr.* = callback;

    try exec.context.scheduler.add(callback, ScheduleCallback.run, delay_ms, .{
        .name = opts.name,
        .low_priority = opts.low_priority,
        .finalizer = ScheduleCallback.cancelled,
    });

    return timer_id;
}

pub fn clear(self: *Timers, id: u32) void {
    var sc = self._callbacks.fetchRemove(id) orelse return;
    sc.value.removed = true;
}

// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#dom-settimeout
// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#timerhandler
// TimerHandler = Function or DOMString. When a string is passed, it is
// compiled into an anonymous function body, matching how legacy browsers
// (and all current UAs) interpret `setTimeout("foo()", 100)`.
pub const LegacyHandler = union(enum) {
    function: js.Function.Temp,
    string: js.String,

    pub fn resolve(handler: LegacyHandler, exec: *js.Execution) !js.Function.Temp {
        switch (handler) {
            .function => |fun| return fun,
            .string => |str| {
                const fun = try exec.context.local.?.compileFunction(str, &.{}, &.{});
                return fun.temp();
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

    cb: js.Function.Temp,

    mode: Mode,
    exec: *js.Execution,
    timers: *Timers,
    arena: Allocator,
    removed: bool = false,
    params: []const js.Value.Temp,

    fn cancelled(ptr: *anyopaque) void {
        var self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinit(self: *ScheduleCallback) void {
        self.cb.release();
        for (self.params) |param| {
            param.release();
        }
        self.exec.releaseArena(self.arena);
    }

    fn run(ptr: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        if (self.removed) {
            self.deinit();
            return null;
        }

        var ls: js.Local.Scope = undefined;
        self.exec.context.localScope(&ls);
        defer ls.deinit();

        switch (self.mode) {
            .idle => {
                const IdleDeadline = @import("IdleDeadline.zig");
                ls.toLocal(self.cb).call(void, .{IdleDeadline{}}) catch |err| {
                    log.warn(.js, "idleCallback", .{ .name = self.name, .err = err });
                };
            },
            .animation_frame => {
                // requestAnimationFrame is window-only; if a worker ever
                // schedules with this mode it's a programming error.
                const window = switch (self.exec.context.global) {
                    .frame => |frame| frame.window,
                    .worker => unreachable,
                };
                ls.toLocal(self.cb).call(void, .{window._performance.now()}) catch |err| {
                    log.warn(.js, "RAF", .{ .name = self.name, .err = err });
                };
            },
            .normal => {
                ls.toLocal(self.cb).call(void, self.params) catch |err| {
                    log.warn(.js, "timer", .{ .name = self.name, .err = err });
                };
            },
        }
        ls.local.runMicrotasks();

        if (self.repeat_ms) |ms| {
            return ms;
        }
        defer self.deinit();
        _ = self.timers._callbacks.remove(self.timer_id);
        return null;
    }
};

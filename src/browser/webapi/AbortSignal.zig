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

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");

const log = lp.log;
const Execution = js.Execution;

const AbortSignal = @This();

_proto: *EventTarget,
_aborted: bool = false,
_is_dependent: bool = false,
_reason: Reason = .undefined,
_on_abort: ?js.Function.Global = null,
_dependents: std.ArrayList(*AbortSignal) = .{},
_source_signals: std.ArrayList(*AbortSignal) = .{},

pub fn init(exec: *const Execution) !*AbortSignal {
    return exec._factory.eventTarget(AbortSignal{
        ._proto = undefined,
    });
}

pub fn getAborted(self: *const AbortSignal) bool {
    return self._aborted;
}

pub fn getReason(self: *const AbortSignal) Reason {
    return self._reason;
}

pub fn getOnAbort(self: *const AbortSignal) ?js.Function.Global {
    return self._on_abort;
}

pub fn setOnAbort(self: *AbortSignal, cb: ?js.Function.Global) !void {
    self._on_abort = cb;
}

pub fn asEventTarget(self: *AbortSignal) *EventTarget {
    return self._proto;
}

pub fn abort(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    if (self._aborted) {
        return;
    }

    try self.markAborted(reason_, exec);

    // Per spec: mark all direct dependents aborted (with this signal's reason)
    // BEFORE firing any abort events. The graph is flattened at any() creation,
    // so we never need to recurse here.
    var to_dispatch: std.ArrayList(*AbortSignal) = .{};
    for (self._dependents.items) |dep| {
        if (dep._aborted) continue;
        try dep.markAborted(self._reason, exec);
        try to_dispatch.append(exec.arena, dep);
    }

    try self.dispatchAbortEvent(exec);
    for (to_dispatch.items) |dep| {
        dep.dispatchAbortEvent(exec) catch |err| {
            log.warn(.app, "abort dependent dispatch", .{ .err = err });
        };
    }
}

fn markAborted(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    self._aborted = true;
    if (reason_) |reason| {
        switch (reason) {
            .dom => |dom| self._reason = .{ .dom = dom },
            .js_val => |js_val| self._reason = .{ .js_val = js_val },
            .string => |str| self._reason = .{ .string = try exec.dupeString(str) },
            .undefined => self._reason = reason,
        }
    } else {
        self._reason = .{ .dom = DOMException.fromError(error.AbortError).? };
    }
}

fn dispatchAbortEvent(self: *AbortSignal, exec: *const Execution) !void {
    const target = self.asEventTarget();
    const on_abort = self._on_abort;
    switch (exec.context.global) {
        inline else => |g| {
            if (g._event_manager.hasDirectListeners(target, "abort", on_abort)) {
                const event = try Event.initTrusted(comptime .wrap("abort"), .{}, g._page);
                try g.dispatch(target, event, on_abort, .{ .context = "abort signal" });
            }
        },
    }
}

// Static method to create an already-aborted signal
pub fn createAborted(reason_: ?js.Value.Global, exec: *const Execution) !*AbortSignal {
    const signal = try init(exec);
    try signal.abort(if (reason_) |r| .{ .js_val = r } else null, exec);
    return signal;
}

pub fn createAny(signals: []const *AbortSignal, exec: *const Execution) !*AbortSignal {
    const result = try init(exec);
    for (signals) |source| {
        if (source._aborted) {
            try result.abort(source._reason, exec);
            return result;
        }
    }

    result._is_dependent = true;

    for (signals) |source| {
        if (!source._is_dependent) {
            try source._dependents.append(exec.arena, result);
            try result._source_signals.append(exec.arena, source);
        } else {
            for (source._source_signals.items) |s| {
                try s._dependents.append(exec.arena, result);
                try result._source_signals.append(exec.arena, s);
            }
        }
    }
    return result;
}

pub fn createTimeout(delay: u32, exec: *const Execution) !*AbortSignal {
    const callback = try exec.arena.create(TimeoutCallback);
    callback.* = .{
        .exec = exec,
        .signal = try init(exec),
    };

    try exec._scheduler.add(callback, TimeoutCallback.run, delay, .{
        .name = "AbortSignal.timeout",
    });

    return callback.signal;
}

const ThrowIfAborted = union(enum) {
    exception: js.Exception,
    undefined: void,
};
pub fn throwIfAborted(self: *const AbortSignal, exec: *const Execution) !ThrowIfAborted {
    const local = exec.context.local.?;

    if (self._aborted) {
        const exception = switch (self._reason) {
            .dom => |err| local.newException(err),
            .string => |str| local.newException(str),
            .js_val => |js_val| local.newException(js_val),
            .undefined => local.newException(DOMException.fromError(error.AbortError).?),
        };
        return .{ .exception = exception };
    }
    return .undefined;
}

const Reason = union(enum) {
    js_val: js.Value.Global,
    dom: DOMException,
    string: []const u8,
    undefined: void,
};

const TimeoutCallback = struct {
    exec: *const Execution,
    signal: *AbortSignal,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *TimeoutCallback = @ptrCast(@alignCast(ctx));
        self.signal.abort(.{ .dom = DOMException.fromError(error.TimeoutError).? }, self.exec) catch |err| {
            log.warn(.app, "abort signal timeout", .{ .err = err });
        };
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbortSignal);

    pub const Meta = struct {
        pub const name = "AbortSignal";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const Prototype = EventTarget;

    pub const constructor = bridge.constructor(AbortSignal.init, .{});
    pub const aborted = bridge.accessor(AbortSignal.getAborted, null, .{});
    pub const reason = bridge.accessor(AbortSignal.getReason, null, .{});
    pub const onabort = bridge.accessor(AbortSignal.getOnAbort, AbortSignal.setOnAbort, .{});
    pub const throwIfAborted = bridge.function(AbortSignal.throwIfAborted, .{});

    // Static method
    pub const abort = bridge.function(AbortSignal.createAborted, .{ .static = true });
    pub const any = bridge.function(AbortSignal.createAny, .{ .static = true });
    pub const timeout = bridge.function(AbortSignal.createTimeout, .{ .static = true });
};

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
const js = @import("../js/js.zig");
const log = @import("../../log.zig");

const Page = @import("../Page.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");

const AbortSignal = @This();

_proto: *EventTarget,
_aborted: bool = false,
_reason: Reason = .undefined,
_on_abort: ?js.Function.Global = null,

pub fn init(page: *Page) !*AbortSignal {
    return page._factory.eventTarget(AbortSignal{
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

pub fn abort(self: *AbortSignal, reason_: ?Reason, local: *const js.Local, page: *Page) !void {
    if (self._aborted) {
        return;
    }

    self._aborted = true;

    // Store the abort reason (default to a simple string if none provided)
    if (reason_) |reason| {
        switch (reason) {
            .js_val => |js_val| self._reason = .{ .js_val = js_val },
            .string => |str| self._reason = .{ .string = try page.dupeString(str) },
            .undefined => self._reason = reason,
        }
    } else {
        self._reason = .{ .string = "AbortError" };
    }

    // Dispatch abort event
    const event = try Event.initTrusted("abort", .{}, page);
    try page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        local.toLocal(self._on_abort),
        .{ .context = "abort signal" },
    );
}

// Static method to create an already-aborted signal
pub fn createAborted(reason_: ?js.Value.Global, page: *Page) !*AbortSignal {
    const signal = try init(page);
    try signal.abort(if (reason_) |r| .{ .js_val = r } else null, page.js.local.?, page);
    return signal;
}

pub fn createTimeout(delay: u32, page: *Page) !*AbortSignal {
    const callback = try page.arena.create(TimeoutCallback);
    callback.* = .{
        .page = page,
        .signal = try init(page),
    };

    try page.scheduler.add(callback, TimeoutCallback.run, delay, .{
        .name = "AbortSignal.timeout",
    });

    return callback.signal;
}

const ThrowIfAborted = union(enum) {
    exception: js.Exception,
    undefined: void,
};
pub fn throwIfAborted(self: *const AbortSignal, page: *Page) !ThrowIfAborted {
    const local = page.js.local.?;

    if (self._aborted) {
        const exception = switch (self._reason) {
            .string => |str| local.throw(str),
            .js_val => |js_val| local.throw(try local.toLocal(js_val).toString(.{ .allocator = page.call_arena })),
            .undefined => local.throw("AbortError"),
        };
        return .{ .exception = exception };
    }
    return .undefined;
}

const Reason = union(enum) {
    js_val: js.Value.Global,
    string: []const u8,
    undefined: void,
};

const TimeoutCallback = struct {
    page: *Page,
    signal: *AbortSignal,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *TimeoutCallback = @ptrCast(@alignCast(ctx));
        var ls: js.Local.Scope = undefined;
        self.page.js.localScope(&ls);
        defer ls.deinit();

        self.signal.abort(.{ .string = "TimeoutError" }, &ls.local, self.page) catch |err| {
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
    };

    pub const Prototype = EventTarget;

    pub const constructor = bridge.constructor(AbortSignal.init, .{});
    pub const aborted = bridge.accessor(AbortSignal.getAborted, null, .{});
    pub const reason = bridge.accessor(AbortSignal.getReason, null, .{});
    pub const onabort = bridge.accessor(AbortSignal.getOnAbort, AbortSignal.setOnAbort, .{});
    pub const throwIfAborted = bridge.function(AbortSignal.throwIfAborted, .{});

    // Static method
    pub const abort = bridge.function(AbortSignal.createAborted, .{ .static = true });
    pub const timeout = bridge.function(AbortSignal.createTimeout, .{ .static = true });
};

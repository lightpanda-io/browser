const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");

const AbortSignal = @This();

_proto: *EventTarget,
_aborted: bool = false,
_reason: ?js.Object = null,
_on_abort: ?js.Function = null,

pub fn init(page: *Page) !*AbortSignal {
    return page._factory.eventTarget(AbortSignal{
        ._proto = undefined,
        ._aborted = false,
        ._reason = null,
        ._on_abort = null,
    });
}

pub fn getAborted(self: *const AbortSignal) bool {
    return self._aborted;
}

pub fn getReason(self: *const AbortSignal) ?js.Object {
    return self._reason;
}

pub fn getOnAbort(self: *const AbortSignal) ?js.Function {
    return self._on_abort;
}

pub fn setOnAbort(self: *AbortSignal, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_abort = try cb.withThis(self);
    } else {
        self._on_abort = null;
    }
}

pub fn asEventTarget(self: *AbortSignal) *EventTarget {
    return self._proto;
}

pub fn abort(self: *AbortSignal, reason_: ?js.Object, page: *Page) !void {
    if (self._aborted) return;

    self._aborted = true;

    // Store the abort reason (default to a simple string if none provided)
    if (reason_) |reason| {
        self._reason = try reason.persist();
    }

    // Dispatch abort event
    const event = try Event.init("abort", .{}, page);
    try page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        self._on_abort,
        .{ .context = "abort signal" },
    );
}

// Static method to create an already-aborted signal
pub fn createAborted(reason_: ?js.Object, page: *Page) !*AbortSignal {
    const signal = try init(page);
    try signal.abort(reason_, page);
    return signal;
}

pub fn throwIfAborted(self: *const AbortSignal) !void {
    if (self._aborted) {
        return error.Aborted;
    }
}

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
};

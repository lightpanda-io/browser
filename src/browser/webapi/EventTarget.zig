const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const RegisterOptions = @import("../EventManager.zig").RegisterOptions;

const Event = @import("Event.zig");

const EventTarget = @This();

_type: Type,

pub const Type = union(enum) {
    node: *@import("Node.zig"),
    window: *@import("Window.zig"),
    xhr: *@import("net/XMLHttpRequestEventTarget.zig"),
    abort_signal: *@import("AbortSignal.zig"),
};

pub fn dispatchEvent(self: *EventTarget, event: *Event, page: *Page) !bool {
    try page._event_manager.dispatch(self, event);
    return !event._cancelable or !event._prevent_default;
}

const addEventListenerOptions = union(enum) {
    capture: bool,
    options: RegisterOptions,
};
pub fn addEventListener(self: *EventTarget, typ: []const u8, callback: js.Function, opts_: ?addEventListenerOptions, page: *Page) !void {
    const options = blk: {
        const o = opts_ orelse break :blk RegisterOptions{};
        break :blk switch (o) {
            .options => |opts| opts,
            .capture => |capture| RegisterOptions{ .capture = capture },
        };
    };
    return page._event_manager.register(self, typ, callback, options);
}

const removeEventListenerOptions = union(enum) {
    capture: bool,
    options: Options,

    const Options = struct {
        useCapture: bool = false,
    };
};
pub fn removeEventListener(self: *EventTarget, typ: []const u8, callback: js.Function, opts_: ?removeEventListenerOptions, page: *Page) !void {
    const use_capture = blk: {
        const o = opts_ orelse break :blk false;
        break :blk switch (o) {
            .capture => |capture| capture,
            .options => |opts| opts.useCapture,
        };
    };
    return page._event_manager.remove(self, typ, callback, use_capture);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventTarget);

    pub const Meta = struct {
        pub const name = "EventTarget";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const dispatchEvent = bridge.function(EventTarget.dispatchEvent, .{});
    pub const addEventListener = bridge.function(EventTarget.addEventListener, .{});
    pub const removeEventListener = bridge.function(EventTarget.removeEventListener, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: EventTarget" {
    // we create thousands of these per page. Nothing should bloat it.
    try testing.expectEqual(16, @sizeOf(EventTarget));

    try testing.htmlRunner("events.html", .{});
}

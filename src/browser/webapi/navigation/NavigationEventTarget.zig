const std = @import("std");
const EventTarget = @import("../EventTarget.zig");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const NavigationCurrentEntryChangeEvent = @import("../event/NavigationCurrentEntryChangeEvent.zig");

pub const NavigationEventTarget = @This();

_proto: *EventTarget,
_on_currententrychange: ?js.Function = null,

pub fn asEventTarget(self: *NavigationEventTarget) *EventTarget {
    return self._proto;
}

const DispatchType = union(enum) {
    currententrychange: *NavigationCurrentEntryChangeEvent,
};

pub fn dispatch(self: *NavigationEventTarget, event_type: DispatchType, page: *Page) !void {
    const event, const field = blk: {
        break :blk switch (event_type) {
            .currententrychange => |cec| .{ cec.asEvent(), "_on_currententrychange" },
        };
    };

    return page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        @field(self, field),
        .{ .context = "Navigation" },
    );
}

pub fn getOnCurrentEntryChange(self: *NavigationEventTarget) ?js.Function {
    return self._on_currententrychange;
}

pub fn setOnCurrentEntryChange(self: *NavigationEventTarget, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_currententrychange = try listen.withThis(self);
    } else {
        self._on_currententrychange = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationEventTarget);

    pub const Meta = struct {
        pub const name = "NavigationEventTarget";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const oncurrententrychange = bridge.accessor(
        NavigationEventTarget.getOnCurrentEntryChange,
        NavigationEventTarget.setOnCurrentEntryChange,
        .{},
    );
};

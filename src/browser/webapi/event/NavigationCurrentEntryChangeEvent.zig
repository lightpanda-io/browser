const std = @import("std");
const Event = @import("../Event.zig");
const Page = @import("../../Page.zig");
const Navigaton = @import("../navigation/Navigation.zig");
const NavigationHistoryEntry = @import("../navigation/NavigationHistoryEntry.zig");
const NavigationType = @import("../navigation/root.zig").NavigationType;
const js = @import("../../js/js.zig");

const NavigationCurrentEntryChangeEvent = @This();

_proto: *Event,
_from: *NavigationHistoryEntry,
_navigation_type: ?NavigationType,

pub const EventInit = struct {
    from: *NavigationHistoryEntry,
    navigationType: ?[]const u8 = null,
};

pub fn init(
    typ: []const u8,
    init_obj: EventInit,
    page: *Page,
) !*NavigationCurrentEntryChangeEvent {
    const navigation_type = if (init_obj.navigationType) |nav_type_str|
        std.meta.stringToEnum(NavigationType, nav_type_str)
    else
        null;

    return page._factory.event(typ, NavigationCurrentEntryChangeEvent{
        ._proto = undefined,
        ._from = init_obj.from,
        ._navigation_type = navigation_type,
    });
}

pub fn asEvent(self: *NavigationCurrentEntryChangeEvent) *Event {
    return self._proto;
}

pub fn getFrom(self: *NavigationCurrentEntryChangeEvent) *NavigationHistoryEntry {
    return self._from;
}

pub fn getNavigationType(self: *const NavigationCurrentEntryChangeEvent) ?[]const u8 {
    return if (self._navigation_type) |nav_type| @tagName(nav_type) else null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationCurrentEntryChangeEvent);

    pub const Meta = struct {
        pub const name = "NavigationCurrentEntryChangeEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(NavigationCurrentEntryChangeEvent.init, .{});
    pub const from = bridge.accessor(NavigationCurrentEntryChangeEvent.getFrom, null, .{});
    pub const navigationType = bridge.accessor(NavigationCurrentEntryChangeEvent.getNavigationType, null, .{});
};

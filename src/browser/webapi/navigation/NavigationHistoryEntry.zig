const std = @import("std");
const URL = @import("../URL.zig");
const EventTarget = @import("../EventTarget.zig");
const NavigationState = @import("root.zig").NavigationState;
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const NavigationHistoryEntry = @This();

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationHistoryEntry
// no proto for now
// _proto: ?*EventTarget,
_id: []const u8,
_key: []const u8,
_url: ?[:0]const u8,
_state: NavigationState,

// fn asEventTarget(self: *NavigationHistoryEntry) *EventTarget {
//     return self._proto.?.asEventTarget();
// }

// pub fn onRemovePage(self: *NavigationHistoryEntry) void {
//     self._proto = null;
// }

// pub fn onNewPage(self: *NavigationHistoryEntry, page: *Page) !void {
//     self._proto = try page._factory.eventTarget(
//         NavigationHistoryEntryEventTarget{ ._proto = undefined },
//     );
// }

pub fn id(self: *const NavigationHistoryEntry) []const u8 {
    return self._id;
}

pub fn index(self: *const NavigationHistoryEntry, page: *Page) i32 {
    const navigation = page._session.navigation;

    for (navigation._entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry._id, self._id)) {
            return @intCast(i);
        }
    }

    return -1;
}

pub fn key(self: *const NavigationHistoryEntry) []const u8 {
    return self._key;
}

pub fn sameDocument(self: *const NavigationHistoryEntry, page: *Page) bool {
    const got_url = self._url orelse return false;
    return URL.eqlDocument(got_url, page.url);
}

pub fn url(self: *const NavigationHistoryEntry) ?[:0]const u8 {
    return self._url;
}

pub const StateReturn = union(enum) { value: ?js.Value, undefined: void };

pub fn getState(self: *const NavigationHistoryEntry, page: *Page) !StateReturn {
    if (self._state.source == .navigation) {
        if (self._state.value) |value| {
            return .{ .value = try js.Value.fromJson(page.js, value) };
        }
    }

    return .undefined;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationHistoryEntry);

    pub const Meta = struct {
        pub const name = "NavigationHistoryEntry";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const id = bridge.accessor(NavigationHistoryEntry.id, null, .{});
    pub const index = bridge.accessor(NavigationHistoryEntry.index, null, .{});
    pub const key = bridge.accessor(NavigationHistoryEntry.key, null, .{});
    pub const sameDocument = bridge.accessor(NavigationHistoryEntry.sameDocument, null, .{});
    pub const url = bridge.accessor(NavigationHistoryEntry.url, null, .{});
    pub const getState = bridge.function(NavigationHistoryEntry.getState, .{});
};

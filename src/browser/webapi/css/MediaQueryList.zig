// zlint-disable unused-decls
const std = @import("std");
const js = @import("../../js/js.zig");
const EventTarget = @import("../EventTarget.zig");

const MediaQueryList = @This();

_proto: *EventTarget,
_media: []const u8,

pub fn deinit(self: *MediaQueryList) void {
    _ = self;
}

pub fn asEventTarget(self: *MediaQueryList) *EventTarget {
    return self._proto;
}

pub fn getMedia(self: *const MediaQueryList) []const u8 {
    return self._media;
}

/// Always returns false for dummy implementation
pub fn getMatches(_: *const MediaQueryList) bool {
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaQueryList);

    pub const Meta = struct {
        pub const name = "MediaQueryList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const media = bridge.accessor(MediaQueryList.getMedia, null, .{});
    pub const matches = bridge.accessor(MediaQueryList.getMatches, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaQueryList" {
    try testing.htmlRunner("css/media_query_list.html", .{});
}

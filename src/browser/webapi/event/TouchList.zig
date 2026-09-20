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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const Touch = @import("Touch.zig");
const TouchEvent = @import("TouchEvent.zig");

// https://w3c.github.io/touch-events/#idl-def-touchlist
//
// Holds the event's single Touch directly instead of a slice, so the (up to)
// three lists a TouchEvent caches never alias a backing array. Refcounting
// delegates to the event.
const TouchList = @This();

_event: *TouchEvent,
_touch: ?*Touch,

pub fn acquireRef(self: *TouchList) void {
    self._event.asEvent().acquireRef();
}

pub fn releaseRef(self: *TouchList, page: *Page) void {
    self._event.asEvent().releaseRef(page);
}

fn length(self: *const TouchList) u32 {
    return if (self._touch != null) 1 else 0;
}

pub fn indexedGet(self: *TouchList, index: usize, _: *Frame) !*Touch {
    if (index != 0) {
        return error.NotHandled;
    }
    return self._touch orelse error.NotHandled;
}

pub fn item(self: *TouchList, index: usize) ?*Touch {
    if (index != 0) {
        return null;
    }
    return self._touch;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TouchList);

    pub const Meta = struct {
        pub const name = "TouchList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(TouchList.length, null, .{});
    pub const @"[]" = bridge.indexed(TouchList.indexedGet, getIndexes, .{ .null_as_undefined = true });
    pub const item = bridge.function(TouchList.item, .{});

    fn getIndexes(self: *TouchList, frame: *Frame) !js.Array {
        const len: u32 = if (self._touch != null) 1 else 0;
        var arr = frame.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};

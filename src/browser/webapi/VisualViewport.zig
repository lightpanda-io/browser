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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const EventTarget = @import("EventTarget.zig");
const Window = @import("Window.zig");

const VisualViewport = @This();

_proto: *EventTarget,

pub fn asEventTarget(self: *VisualViewport) *EventTarget {
    return self._proto;
}

pub fn getPageLeft(_: *const VisualViewport, page: *Page) u32 {
    return page.window.getScrollX();
}

pub fn getPageTop(_: *const VisualViewport, page: *Page) u32 {
    return page.window.getScrollY();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VisualViewport);

    pub const Meta = struct {
        pub const name = "VisualViewport";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Static viewport properties for headless browser
    // No pinch-zoom or mobile viewport, so values are straightforward
    pub const offsetLeft = bridge.property(0, .{ .template = false });
    pub const offsetTop = bridge.property(0, .{ .template = false });
    pub const pageLeft = bridge.accessor(VisualViewport.getPageLeft, null, .{});
    pub const pageTop = bridge.accessor(VisualViewport.getPageTop, null, .{});
    pub const width = bridge.property(1920, .{ .template = false });
    pub const height = bridge.property(1080, .{ .template = false });
    pub const scale = bridge.property(1.0, .{ .template = false });
};

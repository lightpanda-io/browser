// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const Event = @import("../Event.zig");
const Window = @import("../Window.zig");
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const UIEvent = @This();

_proto: *Event,
_detail: u32,
_view: *Window,

pub const EventOptions = struct {
    detail: u32 = 0,
    view: ?*Window = null,
};

pub fn init(typ: []const u8, _options: ?EventOptions, page: *Page) !*UIEvent {
    const options = _options orelse EventOptions{};

    return page._factory.event(typ, UIEvent{
        ._proto = undefined,
        ._detail = options.detail,
        ._view = options.view,
    });
}

pub fn asEvent(self: *UIEvent) *Event {
    return self._proto;
}

pub fn getDetail(self: *UIEvent) u32 {
    return self._detail;
}

// sourceCapabilities not implemented

pub fn getView(self: *UIEvent) *Window {
    return self._view;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(UIEvent);

    pub const Meta = struct {
        pub const name = "UIEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(UIEvent.init, .{});
    pub const detail = bridge.accessor(UIEvent.getDetail, null, .{});
    pub const view = bridge.accessor(UIEvent.getView, null, .{});
};

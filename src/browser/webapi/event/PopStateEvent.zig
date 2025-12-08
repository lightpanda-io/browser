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

const log = @import("../../../log.zig");
// const Window = @import("../html/window.zig").Window;
const Event = @import("../Event.zig");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/PopStateEvent
const PopStateEvent = @This();

const EventOptions = struct {
    state: ?[]const u8 = null,
};

_proto: *Event,
_state: ?[]const u8,

pub fn init(typ: []const u8, _options: ?EventOptions, page: *Page) !*PopStateEvent {
    const options = _options orelse EventOptions{};

    return page._factory.event(typ, PopStateEvent{
        ._proto = undefined,
        ._state = options.state,
    });
}

pub fn asEvent(self: *PopStateEvent) *Event {
    return self._proto;
}

pub fn getState(self: *PopStateEvent, page: *Page) !?js.Value {
    if (self._state == null) return null;

    const value = try js.Value.fromJson(page.js, self._state.?);
    return value;
}

pub fn getUAVisualTransition(_: *PopStateEvent) bool {
    // Not currently supported  so we always return false;
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PopStateEvent);

    pub const Meta = struct {
        pub const name = "PopStateEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PopStateEvent.init, .{});
    pub const state = bridge.accessor(PopStateEvent.getState, null, .{});
    pub const hasUAVisualTransition = bridge.accessor(PopStateEvent.getUAVisualTransition, null, .{});
};

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/PopStateEvent
const PopStateEvent = @This();

_proto: *Event,
_state: ?[]const u8,

const PopStateEventOptions = struct {
    state: ?[]const u8 = null,
};

const Options = Event.inheritOptions(PopStateEvent, PopStateEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*PopStateEvent {
    return initWithTrusted(typ, _opts, false, page);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, page: *Page) !*PopStateEvent {
    return initWithTrusted(typ, _opts, true, page);
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, page: *Page) !*PopStateEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.event(
        typ,
        PopStateEvent{
            ._proto = undefined,
            ._state = opts.state,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *PopStateEvent) *Event {
    return self._proto;
}

pub fn getState(self: *PopStateEvent, page: *Page) !?js.Value {
    const s = self._state orelse return null;
    return try page.js.local.?.parseJSON(s);
}

pub fn hasUAVisualTransition(_: *PopStateEvent) bool {
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
    pub const hasUAVisualTransition = bridge.accessor(PopStateEvent.hasUAVisualTransition, null, .{});
};

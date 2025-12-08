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

// https://developer.mozilla.org/en-US/docs/Web/API/PageTransitionEvent
const PageTransitionEvent = @This();

const EventInit = struct {
    persisted: ?bool = null,
};

_proto: *Event,
_persisted: bool,

pub fn init(typ: []const u8, init_obj: EventInit, page: *Page) !*PageTransitionEvent {
    return page._factory.event(typ, PageTransitionEvent{
        ._proto = undefined,
        ._persisted = init_obj.persisted orelse false,
    });
}

pub fn asEvent(self: *PageTransitionEvent) *Event {
    return self._proto;
}

pub fn getPersisted(self: *PageTransitionEvent) bool {
    return self._persisted;
}

const PageTransitionKind = enum { show, hide };

pub const JsApi = struct {
    pub const bridge = js.Bridge(PageTransitionEvent);

    pub const Meta = struct {
        pub const name = "PageTransitionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PageTransitionEvent.init, .{});
    pub const persisted = bridge.accessor(PageTransitionEvent.getPersisted, null, .{});
};

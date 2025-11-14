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

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");

const ProgressEvent = @This();
_proto: *Event,
_total: usize = 0,
_loaded: usize = 0,
_length_computable: bool = false,

pub fn init(typ: []const u8, total: usize, loaded: usize, page: *Page) !*ProgressEvent {
    return page._factory.event(typ, ProgressEvent{
        ._proto = undefined,
        ._total = total,
        ._loaded = loaded,
    });
}

pub fn asEvent(self: *ProgressEvent) *Event {
    return self._proto;
}

pub fn getTotal(self: *const ProgressEvent) usize {
    return self._total;
}

pub fn getLoaded(self: *const ProgressEvent) usize {
    return self._loaded;
}

pub fn getLengthComputable(self: *const ProgressEvent) bool {
    return self._length_computable;
}

pub const JsApi = struct {
    const js = @import("../../js/js.zig");
    pub const bridge = js.Bridge(ProgressEvent);

    pub const Meta = struct {
        pub const name = "ProgressEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ProgressEvent.init, .{});
    pub const total = bridge.accessor(ProgressEvent.getTotal, null, .{});
    pub const loaded = bridge.accessor(ProgressEvent.getLoaded, null, .{});
    pub const lengthComputable = bridge.accessor(ProgressEvent.getLengthComputable, null, .{});
};

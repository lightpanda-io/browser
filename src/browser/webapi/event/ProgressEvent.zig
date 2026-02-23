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

const std = @import("std");
const String = @import("../../../string.zig").String;

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const ProgressEvent = @This();
_proto: *Event,
_total: usize = 0,
_loaded: usize = 0,
_length_computable: bool = false,

const ProgressEventOptions = struct {
    total: usize = 0,
    loaded: usize = 0,
    lengthComputable: bool = false,
};

const Options = Event.inheritOptions(ProgressEvent, ProgressEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*ProgressEvent {
    const arena = try page.getArena(.{ .debug = "ProgressEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, page);
}

pub fn initTrusted(typ: String, _opts: ?Options, page: *Page) !*ProgressEvent {
    const arena = try page.getArena(.{ .debug = "ProgressEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, page: *Page) !*ProgressEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.event(
        arena,
        typ,
        ProgressEvent{
            ._proto = undefined,
            ._total = opts.total,
            ._loaded = opts.loaded,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *ProgressEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
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
        pub const weak = true;
        pub const finalizer = bridge.finalizer(ProgressEvent.deinit);
    };

    pub const constructor = bridge.constructor(ProgressEvent.init, .{});
    pub const total = bridge.accessor(ProgressEvent.getTotal, null, .{});
    pub const loaded = bridge.accessor(ProgressEvent.getLoaded, null, .{});
    pub const lengthComputable = bridge.accessor(ProgressEvent.getLengthComputable, null, .{});
};

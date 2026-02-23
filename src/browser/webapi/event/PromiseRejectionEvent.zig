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
const std = @import("std");
const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const PromiseRejectionEvent = @This();

_proto: *Event,
_reason: ?js.Value.Temp = null,
_promise: ?js.Promise.Temp = null,

const PromiseRejectionEventOptions = struct {
    reason: ?js.Value.Temp = null,
    promise: ?js.Promise.Temp = null,
};

const Options = Event.inheritOptions(PromiseRejectionEvent, PromiseRejectionEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*PromiseRejectionEvent {
    const arena = try page.getArena(.{ .debug = "PromiseRejectionEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = opts_ orelse Options{};
    const event = try page._factory.event(
        arena,
        type_string,
        PromiseRejectionEvent{
            ._proto = undefined,
            ._reason = opts.reason,
            ._promise = opts.promise,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *PromiseRejectionEvent, shutdown: bool, page: *Page) void {
    if (self._reason) |r| {
        page.js.release(r);
    }
    if (self._promise) |p| {
        page.js.release(p);
    }
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *PromiseRejectionEvent) *Event {
    return self._proto;
}

pub fn getReason(self: *const PromiseRejectionEvent) ?js.Value.Temp {
    return self._reason;
}

pub fn getPromise(self: *const PromiseRejectionEvent) ?js.Promise.Temp {
    return self._promise;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PromiseRejectionEvent);

    pub const Meta = struct {
        pub const name = "PromiseRejectionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(PromiseRejectionEvent.deinit);
    };

    pub const constructor = bridge.constructor(PromiseRejectionEvent.init, .{});
    pub const reason = bridge.accessor(PromiseRejectionEvent.getReason, null, .{});
    pub const promise = bridge.accessor(PromiseRejectionEvent.getPromise, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: PromiseRejectionEvent" {
    try testing.htmlRunner("event/promise_rejection.html", .{});
}

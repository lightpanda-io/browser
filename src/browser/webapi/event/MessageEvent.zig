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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const Window = @import("../Window.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const MessageEvent = @This();

_proto: *Event,
_data: ?Data = null,
_origin: []const u8 = "",
_source: ?*Window = null,

const MessageEventOptions = struct {
    data: ?Data = null,
    origin: ?[]const u8 = null,
    source: ?*Window = null,
};

pub const Data = union(enum) {
    value: js.Value.Temp,
    string: []const u8,
    arraybuffer: js.ArrayBuffer,
    blob: *@import("../Blob.zig"),
};

const Options = Event.inheritOptions(MessageEvent, MessageEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*MessageEvent {
    const arena = try page.getArena(.small, "MessageEvent");
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, page);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*MessageEvent {
    const arena = try page.getArena(.small, "MessageEvent.trusted");
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, trusted: bool, page: *Page) !*MessageEvent {
    const opts = opts_ orelse Options{};

    const event = try page.factory.event(
        arena,
        typ,
        MessageEvent{
            ._proto = undefined,
            ._data = opts.data,
            ._origin = if (opts.origin) |str| try arena.dupe(u8, str) else "",
            ._source = opts.source,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *MessageEvent, page: *Page) void {
    if (self._data) |d| {
        switch (d) {
            .value => |js_val| js_val.release(),
            .blob => |blob| blob.releaseRef(page),
            .string, .arraybuffer => {},
        }
    }
    self._proto.deinit(page);
}

pub fn acquireRef(self: *MessageEvent) void {
    self._proto.acquireRef();
}

pub fn releaseRef(self: *MessageEvent, page: *Page) void {
    self._proto._rc.release(self, page);
}

pub fn asEvent(self: *MessageEvent) *Event {
    return self._proto;
}

pub fn getData(self: *const MessageEvent) ?Data {
    return self._data;
}

pub fn getOrigin(self: *const MessageEvent) []const u8 {
    return self._origin;
}

pub fn getSource(self: *const MessageEvent) ?*Window {
    return self._source;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MessageEvent);

    pub const Meta = struct {
        pub const name = "MessageEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MessageEvent.init, .{});
    pub const data = bridge.accessor(MessageEvent.getData, null, .{});
    pub const origin = bridge.accessor(MessageEvent.getOrigin, null, .{});
    pub const source = bridge.accessor(MessageEvent.getSource, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MessageEvent" {
    try testing.htmlRunner("event/message.html", .{});
}

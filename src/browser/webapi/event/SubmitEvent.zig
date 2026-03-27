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
const Session = @import("../../Session.zig");
const Event = @import("../Event.zig");
const HtmlElement = @import("../element/Html.zig");
const Allocator = std.mem.Allocator;

/// https://developer.mozilla.org/en-US/docs/Web/API/SubmitEvent
const SubmitEvent = @This();

_proto: *Event,
_submitter: ?*HtmlElement,

const SubmitEventOptions = struct {
    submitter: ?*HtmlElement = null,
};

const Options = Event.inheritOptions(SubmitEvent, SubmitEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*SubmitEvent {
    const arena = try page.getArena(.{ .debug = "SubmitEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, page);
}

pub fn initTrusted(typ: String, _opts: ?Options, page: *Page) !*SubmitEvent {
    const arena = try page.getArena(.{ .debug = "SubmitEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, page: *Page) !*SubmitEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.event(
        arena,
        typ,
        SubmitEvent{
            ._proto = undefined,
            ._submitter = opts.submitter,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *SubmitEvent, shutdown: bool, session: *Session) void {
    self._proto.deinit(shutdown, session);
}

pub fn asEvent(self: *SubmitEvent) *Event {
    return self._proto;
}

pub fn getSubmitter(self: *const SubmitEvent) ?*HtmlElement {
    return self._submitter;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SubmitEvent);

    pub const Meta = struct {
        pub const name = "SubmitEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(SubmitEvent.deinit);
    };

    pub const constructor = bridge.constructor(SubmitEvent.init, .{});
    pub const submitter = bridge.accessor(SubmitEvent.getSubmitter, null, .{});
};

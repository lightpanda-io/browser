// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;
const String = @import("../../../string.zig").String;
const Page = @import("../../Page.zig");
const Session = @import("../../Session.zig");
const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");

const FormData = @import("../net/FormData.zig");

/// https://developer.mozilla.org/en-US/docs/Web/API/FormDataEvent
const FormDataEvent = @This();

_proto: *Event,
_form_data: ?*FormData = null,

const Options = Event.inheritOptions(FormDataEvent, struct {
    formData: ?*FormData = null,
});

pub fn init(typ: []const u8, maybe_options: Options, page: *Page) !*FormDataEvent {
    const arena = try page.getArena(.{ .debug = "FormDataEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, maybe_options, false, page);
}

pub fn initTrusted(typ: String, _opts: ?Options, page: *Page) !*FormDataEvent {
    const arena = try page.getArena(.{ .debug = "FormDataEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, maybe_options: ?Options, trusted: bool, page: *Page) !*FormDataEvent {
    const options = maybe_options orelse Options{};

    const event = try page._factory.event(
        arena,
        typ,
        FormDataEvent{
            ._proto = undefined,
            ._form_data = options.formData,
        },
    );

    Event.populatePrototypes(event, options, trusted);
    return event;
}

pub fn deinit(self: *FormDataEvent, shutdown: bool, session: *Session) void {
    self._proto.deinit(shutdown, session);
}

pub fn asEvent(self: *FormDataEvent) *Event {
    return self._proto;
}

pub fn getFormData(self: *const FormDataEvent) ?*FormData {
    return self._form_data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FormDataEvent);

    pub const Meta = struct {
        pub const name = "FormDataEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(FormDataEvent.deinit);
    };

    pub const constructor = bridge.constructor(FormDataEvent.init, .{});
    pub const formData = bridge.accessor(FormDataEvent.getFormData, null, .{});
};

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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");

const FormData = @import("../net/FormData.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

/// https://developer.mozilla.org/en-US/docs/Web/API/FormDataEvent
const FormDataEvent = @This();

_proto: *Event,
_form_data: ?*FormData = null,

const Options = Event.inheritOptions(FormDataEvent, struct {
    formData: ?*FormData = null,
});

pub fn init(typ: []const u8, maybe_options: Options, frame: *Frame) !*FormDataEvent {
    const arena = try frame.getArena(.tiny, "FormDataEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, maybe_options, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*FormDataEvent {
    const arena = try frame.getArena(.tiny, "FormDataEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, maybe_options: ?Options, trusted: bool, frame: *Frame) !*FormDataEvent {
    const options = maybe_options orelse Options{};

    const event = try frame._factory.event(
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
    };

    pub const constructor = bridge.constructor(FormDataEvent.init, .{});
    pub const formData = bridge.accessor(FormDataEvent.getFormData, null, .{});
};

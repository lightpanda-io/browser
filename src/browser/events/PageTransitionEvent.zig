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

const log = @import("../../log.zig");
const Window = @import("../html/window.zig").Window;

const parser = @import("../netsurf.zig");
const Event = @import("../events/event.zig").Event;

// https://developer.mozilla.org/en-US/docs/Web/API/PageTransitionEvent
const PageTransitionEvent = @This();

pub const prototype = *Event;
pub const union_make_copy = true;

pub const EventInit = struct {
    persisted: ?bool,
};

proto: parser.Event,
persisted: bool,

pub fn constructor(event_type: []const u8, opts: EventInit) !PageTransitionEvent {
    const event = try parser.eventCreate();
    defer parser.eventDestroy(event);

    try parser.eventInit(event, event_type, .{});
    parser.eventSetInternalType(event, .page_transition_event);

    return .{
        .proto = event.*,
        .persisted = opts.persisted orelse false,
    };
}

const PageTransitionKind = enum { show, hide };

pub fn dispatch(window: *Window, kind: PageTransitionKind, persisted: bool) void {
    const evt_type = switch (kind) {
        .show => "pageshow",
        .hide => "pagehide",
    };

    log.debug(.script_event, "dispatch event", .{
        .type = evt_type,
        .source = "navigation",
    });

    var evt = PageTransitionEvent.constructor(evt_type, .{ .persisted = persisted }) catch |err| {
        log.err(.app, "event constructor error", .{
            .err = err,
            .type = evt_type,
            .source = "navigation",
        });

        return;
    };

    _ = parser.eventTargetDispatchEvent(
        @as(*parser.EventTarget, @ptrCast(window)),
        &evt.proto,
    ) catch |err| {
        log.err(.app, "dispatch event error", .{
            .err = err,
            .type = evt_type,
            .source = "navigation",
        });
    };
}

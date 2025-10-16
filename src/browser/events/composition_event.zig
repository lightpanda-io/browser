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

const parser = @import("../netsurf.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/CompositionEvent
pub const CompositionEvent = struct {
    data: []const u8,
    proto: parser.Event,

    pub const union_make_copy = true;
    pub const prototype = *parser.Event;

    pub const ConstructorOptions = struct {
        data: []const u8 = "",
    };

    pub fn constructor(event_type: []const u8, options_: ?ConstructorOptions) !CompositionEvent {
        const options: ConstructorOptions = options_ orelse .{};

        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{});
        parser.eventSetInternalType(event, .composition_event);

        return .{
            .proto = event.*,
            .data = options.data,
        };
    }

    pub fn get_data(self: *const CompositionEvent) []const u8 {
        return self.data;
    }
};

const testing = @import("../../testing.zig");
test "Browser: Events.Composition" {
    try testing.htmlRunner("events/composition.html");
}

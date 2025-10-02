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
const js = @import("../js/js.zig");
const parser = @import("../netsurf.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/ErrorEvent
pub const ErrorEvent = struct {
    pub const prototype = *parser.Event;
    pub const union_make_copy = true;

    proto: parser.Event,
    message: []const u8,
    filename: []const u8,
    lineno: i32,
    colno: i32,
    @"error": ?js.Object,

    const ErrorEventInit = struct {
        message: []const u8 = "",
        filename: []const u8 = "",
        lineno: i32 = 0,
        colno: i32 = 0,
        @"error": ?js.Object = null,
    };

    pub fn constructor(event_type: []const u8, opts: ?ErrorEventInit) !ErrorEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{});
        parser.eventSetInternalType(event, .event);

        const o = opts orelse ErrorEventInit{};

        return .{
            .proto = event.*,
            .message = o.message,
            .filename = o.filename,
            .lineno = o.lineno,
            .colno = o.colno,
            .@"error" = if (o.@"error") |e| try e.persist() else null,
        };
    }

    pub fn get_message(self: *const ErrorEvent) []const u8 {
        return self.message;
    }

    pub fn get_filename(self: *const ErrorEvent) []const u8 {
        return self.filename;
    }

    pub fn get_lineno(self: *const ErrorEvent) i32 {
        return self.lineno;
    }

    pub fn get_colno(self: *const ErrorEvent) i32 {
        return self.colno;
    }

    pub fn get_error(self: *const ErrorEvent) js.UndefinedOr(js.Object) {
        if (self.@"error") |e| {
            return .{ .value = e };
        }
        return .undefined;
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.ErrorEvent" {
    try testing.htmlRunner("html/error_event.html");
}

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
const Env = @import("../env.zig").Env;
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
    @"error": ?Env.JsObject,

    const ErrorEventInit = struct {
        message: []const u8 = "",
        filename: []const u8 = "",
        lineno: i32 = 0,
        colno: i32 = 0,
        @"error": ?Env.JsObject = null,
    };

    pub fn constructor(event_type: []const u8, opts: ?ErrorEventInit) !ErrorEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{});
        try parser.eventSetInternalType(event, .event);

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

    const ErrorValue = union(enum) {
        obj: Env.JsObject,
        undefined: void,
    };
    pub fn get_error(self: *const ErrorEvent) ErrorValue {
        if (self.@"error") |e| {
            return .{ .obj = e };
        }
        return .{ .undefined = {} };
    }
};

const testing = @import("../../testing.zig");
test "Browser.HTML.ErrorEvent" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = "<div id=c></div>" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let e1 = new ErrorEvent('err1')", null },
        .{ "e1.message", "" },
        .{ "e1.filename", "" },
        .{ "e1.lineno", "0" },
        .{ "e1.colno", "0" },
        .{ "e1.error", "undefined" },

        .{
            \\ let e2 = new ErrorEvent('err1', {
            \\    message: 'm1',
            \\    filename: 'fx19',
            \\    lineno: 443,
            \\    colno: 8999,
            \\    error: 'under 9000!',
            \\
            \\})
            ,
            null,
        },
        .{ "e2.message", "m1" },
        .{ "e2.filename", "fx19" },
        .{ "e2.lineno", "443" },
        .{ "e2.colno", "8999" },
        .{ "e2.error", "under 9000!" },
    }, .{});
}

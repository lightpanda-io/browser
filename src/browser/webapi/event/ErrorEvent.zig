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
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const ErrorEvent = @This();

_proto: *Event,
_message: []const u8 = "",
_filename: []const u8 = "",
_line_number: u32 = 0,
_column_number: u32 = 0,
_error: ?js.Value.Global = null,
_arena: Allocator,

pub const ErrorEventOptions = struct {
    message: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    lineno: u32 = 0,
    colno: u32 = 0,
    @"error": ?js.Value.Global = null,
};

const Options = Event.inheritOptions(ErrorEvent, ErrorEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*ErrorEvent {
    return initWithTrusted(typ, opts_, false, page);
}

pub fn initTrusted(typ: []const u8, opts_: ?Options, page: *Page) !*ErrorEvent {
    return initWithTrusted(typ, opts_, true, page);
}

fn initWithTrusted(typ: []const u8, opts_: ?Options, trusted: bool, page: *Page) !*ErrorEvent {
    const arena = page.arena;
    const opts = opts_ orelse Options{};

    const event = try page._factory.event(
        typ,
        ErrorEvent{
            ._arena = arena,
            ._proto = undefined,
            ._message = if (opts.message) |str| try arena.dupe(u8, str) else "",
            ._filename = if (opts.filename) |str| try arena.dupe(u8, str) else "",
            ._line_number = opts.lineno,
            ._column_number = opts.colno,
            ._error = opts.@"error",
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *ErrorEvent) *Event {
    return self._proto;
}

pub fn getMessage(self: *const ErrorEvent) []const u8 {
    return self._message;
}

pub fn getFilename(self: *const ErrorEvent) []const u8 {
    return self._filename;
}

pub fn getLineNumber(self: *const ErrorEvent) u32 {
    return self._line_number;
}

pub fn getColumnNumber(self: *const ErrorEvent) u32 {
    return self._column_number;
}

pub fn getError(self: *const ErrorEvent) ?js.Value.Global {
    return self._error;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ErrorEvent);

    pub const Meta = struct {
        pub const name = "ErrorEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Start API
    pub const constructor = bridge.constructor(ErrorEvent.init, .{});
    pub const message = bridge.accessor(ErrorEvent.getMessage, null, .{});
    pub const filename = bridge.accessor(ErrorEvent.getFilename, null, .{});
    pub const lineno = bridge.accessor(ErrorEvent.getLineNumber, null, .{});
    pub const colno = bridge.accessor(ErrorEvent.getColumnNumber, null, .{});
    pub const @"error" = bridge.accessor(ErrorEvent.getError, null, .{ .null_as_undefined = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: ErrorEvent" {
    try testing.htmlRunner("event/error.html", .{});
}

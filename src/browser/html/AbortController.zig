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

const std = @import("std");
const parser = @import("../netsurf.zig");
const EventTarget = @import("../dom/event_target.zig").EventTarget;

pub const Interfaces = .{
    AbortController,
    Signal,
};

const AbortController = @This();

signal: ?Signal = null,

pub fn constructor() AbortController {
    return .{};
}

pub fn get_signal(self: *AbortController) *Signal {
    if (self.signal) |*s| {
        return s;
    }
    self.signal = .init;
    return &self.signal.?;
}

pub fn abort(self: *AbortController, reason_: ?[]const u8) void {
    const signal = &self.signal;

    signal.aborted = true;
    signal.reason = reason_ orelse "AbortError";

    const abort_event = try parser.eventCreate();
    defer parser.eventDestroy(abort_event);
    try parser.eventInit(abort_event, "abort", .{});
    _ = try parser.eventTargetDispatchEvent(
        parser.toEventTarget(Signal, signal),
        abort_event,
    );
}

pub const Signal = struct {
    pub const prototype = *EventTarget;

    aborted: bool,
    reason: ?[]const u8,
    proto: parser.EventTargetTBase,

    pub const init: Signal = .{
        .proto = .{},
        .reason = null,
        .aborted = false,
    };

    pub fn get_aborted(self: *const Signal) bool {
        return self.aborted;
    }

    const Reason = union(enum) {
        reason: []const u8,
        undefined: void,
    };
    pub fn get_reason(self: *const Signal) Reason {
        if (self.reason) |r| {
            return .{ .reason = r };
        }
        return .{ .undefined = {} };
    }
};

const testing = @import("../../testing.zig");
test "Browser.HTML.AbortController" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "var called = false", null },
        .{ "var a1 = new AbortController()", null },
        .{ "var s1 = a1.signal", null },
        .{ "s1.reason", "undefined" },
        .{ "var target;", null },
        .{
            \\ s1.addEventListener('abort', (e) => {
            \\   called = 1;
            \\   target = e.target;
            \\
            \\ });
            \\ target == s1
            , "true" },
        .{ "a1.abort()", null },
        .{ "s1.aborted", "true" },
        .{ "s1.reason", "undefined" },
        .{ "called", "1" },
    }, .{});
}

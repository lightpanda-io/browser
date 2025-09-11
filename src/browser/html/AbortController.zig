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
const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;
const EventTarget = @import("../dom/event_target.zig").EventTarget;

pub const Interfaces = .{
    AbortController,
    AbortSignal,
};

const AbortController = @This();

signal: *AbortSignal,

pub fn constructor(page: *Page) !AbortController {
    // Why do we allocate this rather than storing directly in the struct?
    // https://github.com/lightpanda-io/project/discussions/165
    const signal = try page.arena.create(AbortSignal);
    signal.* = .init;

    return .{
        .signal = signal,
    };
}

pub fn get_signal(self: *AbortController) *AbortSignal {
    return self.signal;
}

pub fn _abort(self: *AbortController, reason_: ?[]const u8) !void {
    return self.signal.abort(reason_);
}

pub const AbortSignal = struct {
    const DEFAULT_REASON = "AbortError";

    pub const prototype = *EventTarget;
    proto: parser.EventTargetTBase = .{ .internal_target_type = .abort_signal },

    aborted: bool,
    reason: ?[]const u8,

    pub const init: AbortSignal = .{
        .reason = null,
        .aborted = false,
    };

    pub fn static_abort(reason_: ?[]const u8) AbortSignal {
        return .{
            .aborted = true,
            .reason = reason_ orelse DEFAULT_REASON,
        };
    }

    pub fn static_timeout(delay: u32, page: *Page) !*AbortSignal {
        const callback = try page.arena.create(TimeoutCallback);
        callback.* = .{
            .signal = .init,
        };

        try page.scheduler.add(callback, TimeoutCallback.run, delay, .{ .name = "abort_signal" });
        return &callback.signal;
    }

    pub fn get_aborted(self: *const AbortSignal) bool {
        return self.aborted;
    }

    fn abort(self: *AbortSignal, reason_: ?[]const u8) !void {
        self.aborted = true;
        self.reason = reason_ orelse DEFAULT_REASON;

        const abort_event = try parser.eventCreate();
        try parser.eventSetInternalType(abort_event, .abort_signal);

        defer parser.eventDestroy(abort_event);
        try parser.eventInit(abort_event, "abort", .{});
        _ = try parser.eventTargetDispatchEvent(
            parser.toEventTarget(AbortSignal, self),
            abort_event,
        );
    }

    const Reason = union(enum) {
        reason: []const u8,
        undefined: void,
    };
    pub fn get_reason(self: *const AbortSignal) Reason {
        if (self.reason) |r| {
            return .{ .reason = r };
        }
        return .{ .undefined = {} };
    }

    const ThrowIfAborted = union(enum) {
        exception: Env.Exception,
        undefined: void,
    };
    pub fn _throwIfAborted(self: *const AbortSignal, page: *Page) ThrowIfAborted {
        if (self.aborted) {
            const ex = page.main_context.throw(self.reason orelse DEFAULT_REASON);
            return .{ .exception = ex };
        }
        return .{ .undefined = {} };
    }
};

const TimeoutCallback = struct {
    signal: AbortSignal,

    fn run(ctx: *anyopaque) ?u32 {
        const self: *TimeoutCallback = @ptrCast(@alignCast(ctx));
        self.signal.abort("TimeoutError") catch |err| {
            log.warn(.app, "abort signal timeout", .{ .err = err });
        };
        return null;
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.AbortController" {
    try testing.htmlRunner("html/abort_controller.html");
}

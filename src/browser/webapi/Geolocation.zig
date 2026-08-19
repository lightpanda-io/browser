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
const lp = @import("lightpanda");
const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const log = lp.log;

const Geolocation = @This();
_pad: bool = false, // avoid zero-size struct pointer collisions (see Permissions.zig)

pub const PositionOptions = struct {
    enableHighAccuracy: bool = false,
    timeout: ?u32 = null,
    maximumAge: u32 = 0,
};

// getCurrentPosition (and, later, watchPosition) must resolve asynchronously
// (WPT/spec requirement): the callbacks can never run synchronously inside
// the call that registered them. Rather than adding new Context/Frame/
// observers plumbing to coalesce deliveries (like IntersectionObserver
// does), each request schedules its own one-shot Task on the frame's
// existing js.Scheduler (frame.js.scheduler) — a simpler, already-proven
// async primitive (see FileReader.ReadTask) that gives us "run later,
// off this call stack" for free, including cleanup on frame teardown via
// the finalizer. watchPosition (Task 4) can layer repeat-in-ms scheduling
// on top of the same Task if it lands here.
const Task = struct {
    success: js.Function.Global,
    error_cb: ?js.Function.Global,
    frame: *Frame,

    fn deinit(self: *Task) void {
        self.success.release();
        if (self.error_cb) |cb| cb.release();
        self.frame._factory.destroy(self);
    }

    // Scheduler finalizer: called if the frame/scheduler is torn down before
    // this task got a chance to run, so the callbacks don't leak.
    fn cancelled(ctx: *anyopaque) void {
        const self: *Task = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn run(ctx: *anyopaque) anyerror!?u32 {
        const self: *Task = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        deliverError(self.frame, self.error_cb);
        return null;
    }
};

// Task 2 only implements the no-override error path: without a
// Browser.geolocation_override, position is unavailable. Reading the
// override into a GeolocationPosition for the success callback is Task 3.
fn deliverError(frame: *Frame, error_cb: ?js.Function.Global) void {
    const err_cb = error_cb orelse return;

    const browser = frame._session.browser;
    const perm = browser.permissions.get("geolocation") orelse .prompt;
    const code: u16 = if (perm == .denied) 1 else 2;
    const message: []const u8 = if (perm == .denied) "User denied Geolocation" else "Position unavailable";

    const err = frame.arena.create(GeolocationPositionError) catch |alloc_err| {
        log.err(.frame, "geolocation.deliverError.alloc", .{ .err = alloc_err });
        return;
    };
    err.* = .{ ._code = code, ._message = message };

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var caught: js.TryCatch.Caught = .{};
    ls.toLocal(err_cb).tryCall(void, .{err}, &caught) catch |call_err| {
        log.err(.frame, "geolocation.deliverError", .{ .err = call_err, .caught = caught });
    };
}

pub fn getCurrentPosition(
    _: *Geolocation,
    success: js.Function.Global,
    error_cb: ?js.Function.Global,
    options: ?PositionOptions,
    frame: *Frame,
) !void {
    _ = options; // unused until Task 3 (maximumAge/timeout) and watchPosition (Task 4)

    errdefer success.release();
    errdefer if (error_cb) |cb| cb.release();

    const task = try frame._factory.create(Task{
        .success = success,
        .error_cb = error_cb,
        .frame = frame,
    });
    errdefer frame._factory.destroy(task);

    try frame.js.scheduler.add(task, Task.run, 0, .{
        .name = "Geolocation.getCurrentPosition",
        .finalizer = Task.cancelled,
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Geolocation);
    pub const Meta = struct {
        pub const name = "Geolocation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const getCurrentPosition = bridge.function(Geolocation.getCurrentPosition, .{});
    // watchPosition / clearWatch come in Task 4
};

pub const GeolocationPositionError = struct {
    _code: u16,
    _message: []const u8,
    pub fn getCode(self: *const GeolocationPositionError) u16 {
        return self._code;
    }
    pub fn getMessage(self: *const GeolocationPositionError) []const u8 {
        return self._message;
    }
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GeolocationPositionError);
        pub const Meta = struct {
            pub const name = "GeolocationPositionError";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const code = bridge.accessor(GeolocationPositionError.getCode, null, .{});
        pub const message = bridge.accessor(GeolocationPositionError.getMessage, null, .{});
        pub const PERMISSION_DENIED = bridge.property(1, .{ .template = true });
        pub const POSITION_UNAVAILABLE = bridge.property(2, .{ .template = true });
        pub const TIMEOUT = bridge.property(3, .{ .template = true });
    };
};

pub fn registerTypes() []const type {
    return &.{ Geolocation, GeolocationPositionError };
}

const testing = @import("../../testing.zig");
test "WebApi: Geolocation" {
    try testing.htmlRunner("geolocation.html", .{});
}

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

const js = @import("../../js/js.zig");
const GeolocationPosition = @import("GeolocationPosition.zig");
const GeolocationPositionError = @import("GeolocationPositionError.zig");

const log = lp.log;

// https://developer.mozilla.org/en-US/docs/Web/API/Geolocation
const Geolocation = @This();

pub const Override = struct {
    latitude: f64,
    longitude: f64,
    accuracy: f64,
};

const PositionOptions = struct {
    enableHighAccuracy: bool = false,
    maximumAge: u32 = 0,
    timeout: ?u32 = null,
};

// Last id handed out by watchPosition. 0 is a sentinel indicating that the
// request is in getCurrentPosition
_watch_id: i32 = 0,

// Watches that haven't delivered yet, so clearWatch can cancel them.
_watches: std.ArrayListUnmanaged(*Request) = .empty,

pub fn getCurrentPosition(
    self: *Geolocation,
    success: js.Function.Global,
    error_cb: ?js.Function.Global,
    options: ?PositionOptions,
    exec: *js.Execution,
) !void {
    _ = options; // enableHighAccuracy/timeout/maximumAge don't apply to a fixed position
    return self.request(0, success, error_cb, exec);
}

pub fn watchPosition(
    self: *Geolocation,
    success: js.Function.Global,
    error_cb: ?js.Function.Global,
    options: ?PositionOptions,
    exec: *js.Execution,
) !i32 {
    _ = options;

    // wrap to 1, 0 is a sentinel
    const watch_id = if (self._watch_id == std.math.maxInt(i32)) 1 else self._watch_id + 1;
    try self.request(watch_id, success, error_cb, exec);
    self._watch_id = watch_id;
    return watch_id;
}

pub fn clearWatch(self: *Geolocation, watch_id: i32) void {
    for (self._watches.items) |req| {
        if (req.watch_id == watch_id) {
            req.cleared = true;
            return;
        }
    }
}

fn request(
    self: *Geolocation,
    watch_id: i32,
    success: js.Function.Global,
    error_cb: ?js.Function.Global,
    exec: *js.Execution,
) !void {
    errdefer success.release();
    errdefer if (error_cb) |cb| cb.release();

    const req = try exec._factory.create(Request{
        .exec = exec,
        .success = success,
        .error_cb = error_cb,
        .watch_id = watch_id,
        .geolocation = self,
    });
    errdefer exec._factory.destroy(req);

    if (watch_id != 0) {
        try self._watches.append(exec.arena, req);
    }
    errdefer if (watch_id != 0) {
        _ = self._watches.pop();
    };

    try exec.js.scheduler.add(req, Request.run, 0, .{
        .name = if (watch_id == 0) "geolocation.getCurrentPosition" else "geolocation.watchPosition",
        .finalizer = Request.cancelled,
    });
}

fn unwatch(self: *Geolocation, req: *Request) void {
    for (self._watches.items, 0..) |candidate, i| {
        if (candidate == req) {
            _ = self._watches.swapRemove(i);
            return;
        }
    }
}

const Request = struct {
    exec: *js.Execution,
    cleared: bool = false,
    geolocation: *Geolocation,
    success: js.Function.Global,
    error_cb: ?js.Function.Global,

    // 0 for getCurrentPosition, else the watchPosition id
    watch_id: i32,

    fn deinit(self: *Request) void {
        self.success.release();
        if (self.error_cb) |cb| {
            cb.release();
        }
        self.exec._factory.destroy(self);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(ctx));
        if (self.watch_id != 0) {
            self.geolocation.unwatch(self);
        }
        self.deinit();
    }

    fn run(ctx: *anyopaque) anyerror!?u32 {
        const self: *Request = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        if (self.watch_id != 0) {
            self.geolocation.unwatch(self);
        }
        if (self.cleared) {
            return null;
        }

        const browser = self.exec.session.browser;

        // Headless Chrome can't answer a permission prompt, so anything short of
        // an explicit grant is a denial - which is why Puppeteer and Playwright
        // both send Browser.grantPermissions alongside setGeolocationOverride.
        if (browser.permissions.get("geolocation") orelse .prompt != .granted) {
            self.deliverError(.permission_denied);
            return null;
        }

        const override = browser.geolocation_override orelse {
            self.deliverError(.position_unavailable);
            return null;
        };
        self.deliverPosition(override);
        return null;
    }

    fn deliverPosition(self: *Request, override: Override) void {
        const exec = self.exec;
        const position = GeolocationPosition.init(exec, override) catch |err| {
            log.err(.js, "geolocation.position", .{ .err = err });
            return;
        };

        // The page can hold on to the position (or its coords), in which case
        // the JS wrapper takes its own ref; ours only has to cover the call.
        position.acquireRef();
        defer position.releaseRef(exec.page);

        self.invoke(self.success, position);
    }

    fn deliverError(self: *Request, code: GeolocationPositionError.Code) void {
        const error_cb = self.error_cb orelse return;

        const exec = self.exec;
        const position_error = GeolocationPositionError.init(exec, code) catch |err| {
            log.err(.js, "geolocation.error", .{ .err = err });
            return;
        };
        position_error.acquireRef();
        defer position_error.releaseRef(exec.page);

        self.invoke(error_cb, position_error);
    }

    fn invoke(self: *Request, callback: js.Function.Global, arg: anytype) void {
        const exec = self.exec;

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        ls.toLocal(callback).call(void, .{arg}) catch |err| {
            exec.page.recordJsError(err);
            log.warn(.js, "geolocation", .{ .err = err });
        };
        ls.local.runMicrotasks();
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Geolocation);

    pub const Meta = struct {
        pub const name = "Geolocation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getCurrentPosition = bridge.function(Geolocation.getCurrentPosition, .{});
    pub const watchPosition = bridge.function(Geolocation.watchPosition, .{});
    pub const clearWatch = bridge.function(Geolocation.clearWatch, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Geolocation" {
    try testing.htmlRunner("geolocation.html", .{});
}

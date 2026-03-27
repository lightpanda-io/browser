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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const log = @import("../log.zig");

const Page = @import("Page.zig");
const Session = @import("Session.zig");
const HttpClient = @import("HttpClient.zig");

const IS_DEBUG = builtin.mode == .Debug;

const Runner = @This();

page: *Page,
session: *Session,
http_client: *HttpClient,

pub const Opts = struct {};

pub fn init(session: *Session, _: Opts) !Runner {
    const page = &(session.page orelse return error.NoPage);

    return .{
        .page = page,
        .session = session,
        .http_client = session.browser.http_client,
    };
}

pub const WaitOpts = struct {
    ms: u32,
    until: lp.Config.WaitUntil = .done,
};
pub fn wait(self: *Runner, opts: WaitOpts) !void {
    _ = try self._wait(false, opts);
}

pub const CDPWaitResult = enum {
    done,
    cdp_socket,
};
pub fn waitCDP(self: *Runner, opts: WaitOpts) !CDPWaitResult {
    return self._wait(true, opts);
}

fn _wait(self: *Runner, comptime is_cdp: bool, opts: WaitOpts) !CDPWaitResult {
    var timer = try std.time.Timer.start();
    var ms_remaining = opts.ms;

    const tick_opts = TickOpts{
        .ms = 200,
        .until = opts.until,
    };
    while (true) {
        const tick_result = self._tick(is_cdp, tick_opts) catch |err| {
            switch (err) {
                error.JsError => {}, // already logged (with hopefully more context)
                else => log.err(.browser, "session wait", .{
                    .err = err,
                    .url = self.page.url,
                }),
            }
            return err;
        };

        const next_ms = switch (tick_result) {
            .ok => |next_ms| next_ms,
            .done => return .done,
            .cdp_socket => if (comptime is_cdp) return .cdp_socket else unreachable,
        };

        const ms_elapsed = timer.lap() / 1_000_000;
        if (ms_elapsed >= ms_remaining) {
            return .done;
        }
        ms_remaining -= @intCast(ms_elapsed);
        if (next_ms > 0) {
            std.Thread.sleep(std.time.ns_per_ms * next_ms);
        }
    }
}

pub const TickOpts = struct {
    ms: u32,
    until: lp.Config.WaitUntil = .done,
};

pub const TickResult = union(enum) {
    done,
    ok: u32,
};
pub fn tick(self: *Runner, opts: TickOpts) !TickResult {
    return switch (try self._tick(false, opts)) {
        .ok => |ms| .{ .ok = ms },
        .done => .done,
        .cdp_socket => unreachable,
    };
}

pub const CDPTickResult = union(enum) {
    done,
    cdp_socket,
    ok: u32,
};
pub fn tickCDP(self: *Runner, opts: TickOpts) !CDPTickResult {
    return self._tick(true, opts);
}

fn _tick(self: *Runner, comptime is_cdp: bool, opts: TickOpts) !CDPTickResult {
    const page = self.page;
    const http_client = self.http_client;

    switch (page._parse_state) {
        .pre, .raw, .text, .image => {
            // The main page hasn't started/finished navigating.
            // There's no JS to run, and no reason to run the scheduler.
            if (http_client.active == 0 and (comptime is_cdp) == false) {
                // haven't started navigating, I guess.
                return .done;
            }

            // Either we have active http connections, or we're in CDP
            // mode with an extra socket. Either way, we're waiting
            // for http traffic
            const http_result = try http_client.tick(@intCast(opts.ms));
            if ((comptime is_cdp) and http_result == .cdp_socket) {
                return .cdp_socket;
            }
            return .{ .ok = 0 };
        },
        .html, .complete => {
            const session = self.session;
            if (session.queued_navigation.items.len != 0) {
                try session.processQueuedNavigation();
                self.page = &session.page.?; // might have changed
                return .{ .ok = 0 };
            }
            const browser = session.browser;

            // The HTML page was parsed. We now either have JS scripts to
            // download, or scheduled tasks to execute, or both.

            // scheduler.run could trigger new http transfers, so do not
            // store http_client.active BEFORE this call and then use
            // it AFTER.
            try browser.runMacrotasks();

            // Each call to this runs scheduled load events.
            try page.dispatchLoad();

            const http_active = http_client.active;
            const total_network_activity = http_active + http_client.intercepted;
            if (page._notified_network_almost_idle.check(total_network_activity <= 2)) {
                page.notifyNetworkAlmostIdle();
            }
            if (page._notified_network_idle.check(total_network_activity == 0)) {
                page.notifyNetworkIdle();
            }

            if (http_active == 0 and (comptime is_cdp == false)) {
                // we don't need to consider http_client.intercepted here
                // because is_cdp is true, and that can only be
                // the case when interception isn't possible.
                if (comptime IS_DEBUG) {
                    std.debug.assert(http_client.intercepted == 0);
                }

                if (browser.hasBackgroundTasks()) {
                    // _we_ have nothing to run, but v8 is working on
                    // background tasks. We'll wait for them.
                    browser.waitForBackgroundTasks();
                }

                switch (opts.until) {
                    .done => {},
                    .domcontentloaded => if (page._load_state == .load or page._load_state == .complete) {
                        return .done;
                    },
                    .load => if (page._load_state == .complete) {
                        return .done;
                    },
                    .networkidle => if (page._notified_network_idle == .done) {
                        return .done;
                    },
                }

                // We never advertise a wait time of more than 20, there can
                // always be new background tasks to run.
                if (browser.msToNextMacrotask()) |ms_to_next_task| {
                    return .{ .ok = @min(ms_to_next_task, 20) };
                }
                return .done;
            }

            // We're here because we either have active HTTP
            // connections, or is_cdp == false (aka, there's
            // an cdp_socket registered with the http client).
            // We should continue to run tasks, so we minimize how long
            // we'll poll for network I/O.
            var ms_to_wait = @min(opts.ms, browser.msToNextMacrotask() orelse 200);
            if (ms_to_wait > 10 and browser.hasBackgroundTasks()) {
                // if we have background tasks, we don't want to wait too
                // long for a message from the client. We want to go back
                // to the top of the loop and run macrotasks.
                ms_to_wait = 10;
            }
            const http_result = try http_client.tick(@intCast(@min(opts.ms, ms_to_wait)));
            if ((comptime is_cdp) and http_result == .cdp_socket) {
                return .cdp_socket;
            }
            return .{ .ok = 0 };
        },
        .err => |err| {
            page._parse_state = .{ .raw_done = @errorName(err) };
            return err;
        },
        .raw_done => return .done,
    }
}

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

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const js = @import("js/js.zig");
const log = @import("../log.zig");
const App = @import("../App.zig");
const HttpClient = @import("../http/Client.zig");
const storage = @import("webapi/storage/storage.zig");
const indexed_db = @import("webapi/storage/indexed_db.zig");

const ArenaPool = App.ArenaPool;
const CookieJar = @import("webapi/storage/Cookie.zig").Jar;

const IS_DEBUG = @import("builtin").mode == .Debug;

const Session = @import("Session.zig");
const Notification = @import("../Notification.zig");

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
const Browser = @This();

env: js.Env,
app: *App,
session: ?Session,
allocator: Allocator,
arena_pool: *ArenaPool,
http_client: *HttpClient,
allow_script_popups: bool = true,
shared_cookie_jar: ?*CookieJar = null,
shared_storage_shed: ?*storage.Shed = null,
shared_indexed_db_shed: ?*indexed_db.Shed = null,

const InitOpts = struct {
    env: js.Env.InitOpts = .{},
    http_client: *HttpClient,
    shared_cookie_jar: ?*CookieJar = null,
    shared_storage_shed: ?*storage.Shed = null,
    shared_indexed_db_shed: ?*indexed_db.Shed = null,
};

pub fn init(app: *App, opts: InitOpts) !Browser {
    const allocator = app.allocator;

    var env = try js.Env.init(app, opts.env);
    errdefer env.deinit();

    return .{
        .app = app,
        .env = env,
        .session = null,
        .allocator = allocator,
        .arena_pool = &app.arena_pool,
        .http_client = opts.http_client,
        .allow_script_popups = true,
        .shared_cookie_jar = opts.shared_cookie_jar,
        .shared_storage_shed = opts.shared_storage_shed,
        .shared_indexed_db_shed = opts.shared_indexed_db_shed,
    };
}

pub fn deinit(self: *Browser) void {
    self.closeSession();
    self.env.deinit();
}

pub fn newSession(self: *Browser, notification: *Notification) !*Session {
    self.closeSession();
    self.session = @as(Session, undefined);
    const session = &self.session.?;
    try Session.init(session, self, notification);
    return session;
}

pub fn closeSession(self: *Browser) void {
    if (self.session) |*session| {
        session.deinit();
        self.session = null;
        self.env.memoryPressureNotification(.critical);
    }
}

pub fn runMicrotasks(self: *Browser) void {
    self.env.isolate.enter();
    defer self.env.isolate.exit();
    self.env.runMicrotasks();
}

pub fn runMacrotasks(self: *Browser) !?u64 {
    const env = &self.env;
    env.isolate.enter();
    defer env.isolate.exit();

    var time_to_next: ?u64 = null;
    var iterations: usize = 0;
    while (iterations < 32) : (iterations += 1) {
        var iteration_next = try self.env.runMacrotasks();
        const pumped_message = env.pumpMessageLoopStep();
        if (pumped_message and (iteration_next == null or iteration_next.? > 1)) {
            iteration_next = 1;
        }

        // Either the scheduler still has ready work (0ms) or V8/platform
        // just pumped a message that can queue immediate follow-up tasks.
        // Drain a bounded burst here so async startup chains settle without
        // forcing the outer wait loop to interleave unrelated input.
        if (iteration_next) |delay| {
            time_to_next = if (time_to_next) |current| @min(current, delay) else delay;
        }

        // Either of the above could have queued more microtasks.
        env.runMicrotasks();

        if (pumped_message) {
            continue;
        }
        if (iteration_next) |delay| {
            if (delay == 0) {
                continue;
            }
        }
        break;
    }

    return time_to_next;
}

pub fn hasBackgroundTasks(self: *Browser) bool {
    self.env.isolate.enter();
    defer self.env.isolate.exit();
    return self.env.hasBackgroundTasks();
}
pub fn waitForBackgroundTasks(self: *Browser) void {
    self.env.isolate.enter();
    defer self.env.isolate.exit();
    self.env.waitForBackgroundTasks();
}

pub fn runIdleTasks(self: *const Browser) void {
    self.env.isolate.enter();
    defer self.env.isolate.exit();
    self.env.runIdleTasks();
}

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
const Http = @import("../http/Http.zig");
const HttpClient = @import("../http/Client.zig");
const Notification = @import("../Notification.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const Session = @import("Session.zig");

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
const Browser = @This();

env: js.Env,
app: *App,
session: ?Session,
allocator: Allocator,
http_client: *HttpClient,
call_arena: ArenaAllocator,
page_arena: ArenaAllocator,
session_arena: ArenaAllocator,
transfer_arena: ArenaAllocator,
notification: *Notification,

pub fn init(app: *App, http: *Http) !Browser {
    const allocator = app.allocator;

    var env = try js.Env.init(allocator, &app.platform, &app.snapshot);
    errdefer env.deinit();

    const notification = try Notification.init(allocator, app.notification);
    http.client.notification = notification;
    http.client.next_request_id = 0; // Should we track ids in CDP only?
    errdefer notification.deinit();

    return .{
        .app = app,
        .env = env,
        .session = null,
        .allocator = allocator,
        .notification = notification,
        .http_client = http.client,
        .call_arena = ArenaAllocator.init(allocator),
        .page_arena = ArenaAllocator.init(allocator),
        .session_arena = ArenaAllocator.init(allocator),
        .transfer_arena = ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Browser) void {
    self.closeSession();
    self.env.deinit();
    self.call_arena.deinit();
    self.page_arena.deinit();
    self.session_arena.deinit();
    self.transfer_arena.deinit();
    self.http_client.notification = null;
    self.notification.deinit();
}

pub fn newSession(self: *Browser) !*Session {
    self.closeSession();
    self.session = @as(Session, undefined);
    const session = &self.session.?;
    try Session.init(session, self);
    return session;
}

pub fn closeSession(self: *Browser) void {
    if (self.session) |*session| {
        session.deinit();
        self.session = null;
        _ = self.session_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });
        self.env.lowMemoryNotification();
    }
}

pub fn runMicrotasks(self: *const Browser) void {
    self.env.runMicrotasks();
}

pub fn runMessageLoop(self: *const Browser) void {
    while (self.env.pumpMessageLoop()) {
        if (comptime IS_DEBUG) {
            log.debug(.browser, "pumpMessageLoop", .{});
        }
    }
    self.env.runIdleTasks();
}

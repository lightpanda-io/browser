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

const App = @import("../App.zig");
const Watchdog = @import("../Watchdog.zig");
const Notification = @import("../Notification.zig");
const HttpClient = @import("../network/HttpClient.zig");

const js = @import("js/js.zig");
const Page = @import("Page.zig");
const Session = @import("Session.zig");
const Viewport = @import("Viewport.zig");
const Selector = @import("webapi/selector/Selector.zig");
const Geolocation = @import("webapi/geolocation/Geolocation.zig");
const PermissionState = @import("webapi/Permissions.zig").State;

const ArenaPool = App.ArenaPool;
const Allocator = std.mem.Allocator;

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
const Browser = @This();

env: js.Env,
app: *App,
session: ?Session,
allocator: Allocator,
arena_pool: *ArenaPool,
http_client: HttpClient,

// Shared across pages, survives navigation. See Selector.Cache.
selector_cache: Selector.Cache,

// Pinned-arena bytes we haven't told v8 about yet
arena_account: lp.Arena.Account = .{},

// Our isolate's heap size as of the last reportJsHeap().
last_reported_js_bytes: usize = 0,

// Permission state set via CDP Browser.grantPermissions / setPermission /
// resetPermissions, keyed by permission name (e.g. "geolocation"). Read back
// by navigator.permissions.query(). Scoped to the Browser so it persists
// across page navigations, mirroring how Chrome scopes permissions to the
// browser context. Keys are owned by `allocator`; values are enum tags.
permissions: std.StringHashMapUnmanaged(PermissionState) = .empty,

// Runtime viewport override
viewport_override: ?Viewport = null,

// Screenshot renderer (fonts, glyph cache); created on the first screenshot.
renderer: ?*lp.screenshot.Renderer = null,

// Runtime geolocation override
geolocation_override: ?Geolocation.Override = null,

// used by sessions to allocate pages.
page_pool: std.heap.MemoryPool(Page),

// Registered with App.watchdog for the lifetime of the env. The watchdog
// checker thread reads it until Browser.deinit unregisters.
watchdog_entry: Watchdog.Entry,

// Pool for FinalizerCallback.Identity structs — the records V8 weak-callback
// parameters point at. Scoped to the Browser (i.e. the V8 Isolate's lifetime)
// rather than the Session: V8 can run a weak finalizer arbitrarily late, any
// time up until the Isolate is torn down, so these must outlive every Session.
// Freed in deinit *after* env.deinit() tears down the Isolate — the point past
// which no finalizer can fire.
fc_identity_pool: std.heap.MemoryPool(js.FinalizerCallback.Identity),

// Monotonic frame-ID generator scoped to this Browser (one per CDP
// connection). Lives here, not on Session, because CDP target IDs
// (encoded as `FID-{d:0>10}`) must be unique for the lifetime of the
// connection -- a Session-scoped counter would re-issue the same
// `FID-0000000001` for every fresh BrowserContext on the connection,
// which Playwright rejects with `Duplicate target FID-...` (issue
// #2472).
frame_id_gen: u32 = 0,

const InitOpts = struct {
    env: js.Env.InitOpts = .{},
};

// Allocate the next frame ID. Wrapping `+%` keeps this safe past 2^32
// allocations on a single connection (which would take days of
// continuous navigation; in practice we wrap the connection long
// before that). Callers must format with `FID-{d:0>10}` to match the
// existing CDP target-ID encoding (`src/cdp/id.zig`).
pub fn nextFrameId(self: *Browser) u32 {
    const id = self.frame_id_gen +% 1;
    self.frame_id_gen = id;
    return id;
}

pub fn init(self: *Browser, app: *App, opts: InitOpts) !void {
    const allocator = app.allocator;

    var env = try js.Env.init(app, opts.env);
    errdefer env.deinit();

    self.* = .{
        .app = app,
        .env = env,
        .session = null,
        .page_pool = .empty,
        .allocator = allocator,
        .arena_pool = &app.arena_pool,
        .http_client = undefined,
        .fc_identity_pool = .empty,
        .selector_cache = .init(allocator),
        .watchdog_entry = undefined,
    };
    self.env.protectHeapLimit();
    try self.http_client.init(app);

    self.watchdog_entry = .{
        .env = &self.env,
        .heartbeat = &self.http_client.heartbeat,
    };
    app.watchdog.register(&self.watchdog_entry);
}

pub fn deinit(self: *Browser) void {
    const allocator = self.allocator;

    self.prepareForTeardown();

    self.closeSession();

    lp.metrics.js_heap_physical_bytes.add(-@as(i64, @intCast(self.last_reported_js_bytes)));
    self.last_reported_js_bytes = 0;

    self.env.deinit();
    // After env.deinit() the Isolate is gone, so no further weak finalizer can
    // fire — only now is it safe to free the pool backing their parameters.
    self.fc_identity_pool.deinit(allocator);
    self.page_pool.deinit(allocator);
    self.http_client.deinit();
    if (self.renderer) |r| r.deinit();
    self.clearPermissions();
    self.permissions.deinit(allocator);
    self.selector_cache.deinit();
}

// Wait out a watchdog scan before clearing its termination request.
pub fn prepareForTeardown(self: *Browser) void {
    self.app.watchdog.unregister(&self.watchdog_entry);
    self.env.cancelTerminate();
}

// Set (or overwrite) the stored state for a permission. The name is duped into
// `allocator`; the state is a plain enum tag. Used by CDP
// Browser.grantPermissions / setPermission.
pub fn setPermission(self: *Browser, name: []const u8, state: PermissionState) !void {
    const gop = try self.permissions.getOrPut(self.allocator, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = self.allocator.dupe(u8, name) catch |err| {
            _ = self.permissions.remove(name);
            return err;
        };
    }
    gop.value_ptr.* = state;
}

// Clear all stored permissions, freeing the keys. Used by CDP
// Browser.resetPermissions and on teardown.
pub fn clearPermissions(self: *Browser) void {
    var it = self.permissions.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.permissions.clearRetainingCapacity();
}

// The viewport every consumer should read: the runtime override if set,
// otherwise the compile-time default.
pub fn setViewportOverride(self: *Browser, viewport: ?Viewport) void {
    self.viewport_override = viewport;
    const session = &(self.session orelse return);
    for (session.pages.items) |page| page.viewportChanged();
}

pub fn getViewport(self: *const Browser) Viewport {
    return self.viewport_override orelse Viewport.default;
}

pub fn newSession(self: *Browser, notification: *Notification) !*Session {
    self.closeSession();
    self.session = @as(Session, undefined);
    errdefer self.session = null;
    const session = &self.session.?;
    try Session.init(session, self, notification);
    return session;
}

pub fn closeSession(self: *Browser) void {
    if (self.session) |*session| {
        session.deinit();
        self.session = null;
    }
    self.flushArenaMemory();
}

// Tell v8 the net change in pinned native memory. This can start a GC.
pub fn flushArenaMemory(self: *Browser) void {
    const delta = self.arena_account.pending;
    if (delta == 0) {
        return;
    }
    self.arena_account.pending = 0;
    self.env.isolate.adjustAmountOfExternalAllocatedMemory(delta);
}

pub fn reportJsHeap(self: *Browser) void {
    const bytes = self.env.isolate.getHeapStatistics().total_physical_size;
    lp.metrics.js_heap_physical_bytes.add(@as(i64, @intCast(bytes)) - @as(i64, @intCast(self.last_reported_js_bytes)));
    self.last_reported_js_bytes = bytes;
}

pub fn runMicrotasks(self: *Browser) void {
    self.env.runMicrotasks();
}

pub fn runMacrotasks(self: *Browser) !void {
    const env = &self.env;

    try self.env.runMacrotasks();
    env.pumpMessageLoop();

    // either of the above could have queued more microtasks
    env.runMicrotasks();
}

pub fn hasBackgroundTasks(self: *Browser) bool {
    return self.env.hasBackgroundTasks();
}

pub fn waitForBackgroundTasks(self: *Browser) void {
    self.env.waitForBackgroundTasks();
}

pub fn hasMacrotasks(self: *Browser) bool {
    return self.env.hasMacrotasks();
}

pub fn msToNextTask(self: *Browser) ?u64 {
    return self.env.msToNextTask();
}

pub fn runIdleTasks(self: *const Browser) void {
    self.env.runIdleTasks();
}

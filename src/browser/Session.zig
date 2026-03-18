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
const App = @import("../App.zig");

const js = @import("js/js.zig");
const storage = @import("webapi/storage/storage.zig");
const Navigation = @import("webapi/navigation/Navigation.zig");
const History = @import("webapi/History.zig");

const Page = @import("Page.zig");
const Browser = @import("Browser.zig");
const Factory = @import("Factory.zig");
const Notification = @import("../Notification.zig");
const QueuedNavigation = Page.QueuedNavigation;

const Allocator = std.mem.Allocator;
const ArenaPool = App.ArenaPool;
const IS_DEBUG = builtin.mode == .Debug;

// You can create successively multiple pages for a session, but you must
// deinit a page before running another one. It manages two distinct lifetimes.
//
// The first is the lifetime of the Session itself, where pages are created and
// removed, but share the same cookie jar and navigation history (etc...)
//
// The second is as a container the data needed by the full page hierarchy, i.e. \
// the root page and all of its frames (and all of their frames.)
const Session = @This();

// These are the fields that remain intact for the duration of the Session
browser: *Browser,
arena: Allocator,
history: History,
navigation: Navigation,
storage_shed: storage.Shed,
notification: *Notification,
cookie_jar: storage.Cookie.Jar,

// These are the fields that get reset whenever the Session's page (the root) is reset.
factory: Factory,

page_arena: Allocator,

// Origin map for same-origin context sharing. Scoped to the root page lifetime.
origins: std.StringHashMapUnmanaged(*js.Origin) = .empty,

// Shared resources for all pages in this session.
// These live for the duration of the page tree (root + frames).
arena_pool: *ArenaPool,

// In Debug, we use this to see if anything fails to release an arena back to
// the pool.
_arena_pool_leak_track: if (IS_DEBUG) std.AutoHashMapUnmanaged(usize, struct {
    owner: []const u8,
    count: usize,
}) else void = if (IS_DEBUG) .empty else {},

page: ?Page,

queued_navigation: std.ArrayList(*Page),
// Temporary buffer for about:blank navigations during processing.
// We process async navigations first (safe from re-entrance), then sync
// about:blank navigations (which may add to queued_navigation).
queued_queued_navigation: std.ArrayList(*Page),

page_id_gen: u32,
frame_id_gen: u32,

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena_pool = browser.arena_pool;

    const arena = try arena_pool.acquire();
    errdefer arena_pool.release(arena);

    const page_arena = try arena_pool.acquire();
    errdefer arena_pool.release(page_arena);

    self.* = .{
        .page = null,
        .arena = arena,
        .arena_pool = arena_pool,
        .page_arena = page_arena,
        .factory = Factory.init(page_arena),
        .history = .{},
        .page_id_gen = 0,
        .frame_id_gen = 0,
        // The prototype (EventTarget) for Navigation is created when a Page is created.
        .navigation = .{ ._proto = undefined },
        .storage_shed = .{},
        .browser = browser,
        .queued_navigation = .{},
        .queued_queued_navigation = .{},
        .notification = notification,
        .cookie_jar = storage.Cookie.Jar.init(allocator),
    };
}

pub fn deinit(self: *Session) void {
    if (self.page != null) {
        self.removePage();
    }
    self.cookie_jar.deinit();

    self.storage_shed.deinit(self.browser.app.allocator);
    self.arena_pool.release(self.page_arena);
    self.arena_pool.release(self.arena);
}

// NOTE: the caller is not the owner of the returned value,
// the pointer on Page is just returned as a convenience
pub fn createPage(self: *Session) !*Page {
    lp.assert(self.page == null, "Session.createPage - page not null", .{});

    self.page = @as(Page, undefined);
    const page = &self.page.?;
    try Page.init(page, self.nextFrameId(), self, null);

    // Creates a new NavigationEventTarget for this page.
    try self.navigation.onNewPage(page);

    if (comptime IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }
    // start JS env
    // Inform CDP the main page has been created such that additional context for other Worlds can be created as well
    self.notification.dispatch(.page_created, page);

    return page;
}

pub fn removePage(self: *Session) void {
    // Inform CDP the page is going to be removed, allowing other worlds to remove themselves before the main one
    self.notification.dispatch(.page_remove, .{});
    lp.assert(self.page != null, "Session.removePage - page is null", .{});

    self.page.?.deinit(false);
    self.page = null;

    self.navigation.onRemovePage();
    self.resetPageResources();

    if (comptime IS_DEBUG) {
        log.debug(.browser, "remove page", .{});
    }
}

pub const GetArenaOpts = struct {
    debug: []const u8,
};

pub fn getArena(self: *Session, opts: GetArenaOpts) !Allocator {
    const allocator = try self.arena_pool.acquire();
    if (comptime IS_DEBUG) {
        // Use session's arena (not page_arena) since page_arena gets reset between pages
        const gop = try self._arena_pool_leak_track.getOrPut(self.arena, @intFromPtr(allocator.ptr));
        if (gop.found_existing and gop.value_ptr.count != 0) {
            log.err(.bug, "ArenaPool Double Use", .{ .owner = gop.value_ptr.*.owner });
            @panic("ArenaPool Double Use");
        }
        gop.value_ptr.* = .{ .owner = opts.debug, .count = 1 };
    }
    return allocator;
}

pub fn releaseArena(self: *Session, allocator: Allocator) void {
    if (comptime IS_DEBUG) {
        const found = self._arena_pool_leak_track.getPtr(@intFromPtr(allocator.ptr)).?;
        if (found.count != 1) {
            log.err(.bug, "ArenaPool Double Free", .{ .owner = found.owner, .count = found.count });
            if (comptime builtin.is_test) {
                @panic("ArenaPool Double Free");
            }
            return;
        }
        found.count = 0;
    }
    return self.arena_pool.release(allocator);
}

pub fn getOrCreateOrigin(self: *Session, key_: ?[]const u8) !*js.Origin {
    const key = key_ orelse {
        var opaque_origin: [36]u8 = undefined;
        @import("../id.zig").uuidv4(&opaque_origin);
        // Origin.init will dupe opaque_origin. It's fine that this doesn't
        // get added to self.origins. In fact, it further isolates it. When the
        // context is freed, it'll call session.releaseOrigin which will free it.
        return js.Origin.init(self.browser.app, self.browser.env.isolate, &opaque_origin);
    };

    const gop = try self.origins.getOrPut(self.arena, key);
    if (gop.found_existing) {
        const origin = gop.value_ptr.*;
        origin.rc += 1;
        return origin;
    }

    errdefer _ = self.origins.remove(key);

    const origin = try js.Origin.init(self.browser.app, self.browser.env.isolate, key);
    gop.key_ptr.* = origin.key;
    gop.value_ptr.* = origin;
    return origin;
}

pub fn releaseOrigin(self: *Session, origin: *js.Origin) void {
    const rc = origin.rc;
    if (rc == 1) {
        _ = self.origins.remove(origin.key);
        origin.deinit(self.browser.app);
    } else {
        origin.rc = rc - 1;
    }
}

/// Reset page_arena and factory for a clean slate.
/// Called when root page is removed.
fn resetPageResources(self: *Session) void {
    // Check for arena leaks before releasing
    if (comptime IS_DEBUG) {
        var it = self._arena_pool_leak_track.valueIterator();
        while (it.next()) |value_ptr| {
            if (value_ptr.count > 0) {
                log.err(.bug, "ArenaPool Leak", .{ .owner = value_ptr.owner });
            }
        }
        self._arena_pool_leak_track.clearRetainingCapacity();
    }

    // All origins should have been released when contexts were destroyed
    if (comptime IS_DEBUG) {
        std.debug.assert(self.origins.count() == 0);
    }
    // Defensive cleanup in case origins leaked
    {
        const app = self.browser.app;
        var it = self.origins.valueIterator();
        while (it.next()) |value| {
            value.*.deinit(app);
        }
        self.origins.clearRetainingCapacity();
    }

    // Release old page_arena and acquire fresh one
    self.frame_id_gen = 0;
    self.arena_pool.reset(self.page_arena, 64 * 1024);
    self.factory = Factory.init(self.page_arena);
}

pub fn replacePage(self: *Session) !*Page {
    if (comptime IS_DEBUG) {
        log.debug(.browser, "replace page", .{});
    }

    lp.assert(self.page != null, "Session.replacePage null page", .{});
    lp.assert(self.page.?.parent == null, "Session.replacePage with parent", .{});

    var current = self.page.?;
    const frame_id = current._frame_id;
    current.deinit(true);

    self.resetPageResources();
    self.browser.env.memoryPressureNotification(.moderate);

    self.page = @as(Page, undefined);
    const page = &self.page.?;
    try Page.init(page, frame_id, self, null);
    return page;
}

pub fn currentPage(self: *Session) ?*Page {
    return &(self.page orelse return null);
}

pub const WaitResult = enum {
    done,
    no_page,
    cdp_socket,
};

pub fn findPageByFrameId(self: *Session, frame_id: u32) ?*Page {
    const page = self.currentPage() orelse return null;
    return findPageBy(page, "_frame_id", frame_id);
}

pub fn findPageById(self: *Session, id: u32) ?*Page {
    const page = self.currentPage() orelse return null;
    return findPageBy(page, "id", id);
}

fn findPageBy(page: *Page, comptime field: []const u8, id: u32) ?*Page {
    if (@field(page, field) == id) return page;
    for (page.frames.items) |f| {
        if (findPageBy(f, field, id)) |found| {
            return found;
        }
    }
    return null;
}

pub fn wait(self: *Session, wait_ms: u32, wait_until: lp.Config.WaitUntil) WaitResult {
    var page = &(self.page orelse return .no_page);
    while (true) {
        const wait_result = self._wait(&page, wait_ms, wait_until) catch |err| {
            switch (err) {
                error.JsError => {}, // already logged (with hopefully more context)
                else => log.err(.browser, "session wait", .{
                    .err = err,
                    .url = page.*.url,
                }),
            }
            return .done;
        };

        switch (wait_result) {
            .done => {
                if (self.queued_navigation.items.len == 0) {
                    return .done;
                }
                self.processQueuedNavigation() catch return .done;
                page = &self.page.?; // might have changed
            },
            else => |result| return result,
        }
    }
}

fn _wait(self: *Session, page: **Page, wait_ms: u32, wait_until: lp.Config.WaitUntil) !WaitResult {
    var timer = try std.time.Timer.start();
    var ms_remaining = wait_ms;

    const browser = self.browser;
    var http_client = browser.http_client;

    // I'd like the page to know NOTHING about cdp_socket / CDP, but the
    // fact is that the behavior of wait changes depending on whether or
    // not we're using CDP.
    // If we aren't using CDP, as soon as we think there's nothing left
    // to do, we can exit - we'de done.
    // But if we are using CDP, we should wait for the whole `wait_ms`
    // because the http_click.tick() also monitors the CDP socket. And while
    // we could let CDP poll http (like it does for HTTP requests), the fact
    // is that we know more about the timing of stuff (e.g. how long to
    // poll/sleep) in the page.
    const exit_when_done = http_client.cdp_client == null;

    while (true) {
        switch (page.*._parse_state) {
            .pre, .raw, .text, .image => {
                // The main page hasn't started/finished navigating.
                // There's no JS to run, and no reason to run the scheduler.
                if (http_client.active == 0 and exit_when_done) {
                    // haven't started navigating, I guess.
                    if (wait_until != .fixed) {
                        return .done;
                    }
                }
                // Either we have active http connections, or we're in CDP
                // mode with an extra socket. Either way, we're waiting
                // for http traffic
                if (try http_client.tick(@intCast(ms_remaining)) == .cdp_socket) {
                    // exit_when_done is explicitly set when there isn't
                    // an extra socket, so it should not be possibl to
                    // get an cdp_socket message when exit_when_done
                    // is true.
                    if (IS_DEBUG) {
                        std.debug.assert(exit_when_done == false);
                    }

                    // data on a socket we aren't handling, return to caller
                    return .cdp_socket;
                }
            },
            .html, .complete => {
                if (self.queued_navigation.items.len != 0) {
                    return .done;
                }

                // The HTML page was parsed. We now either have JS scripts to
                // download, or scheduled tasks to execute, or both.

                // scheduler.run could trigger new http transfers, so do not
                // store http_client.active BEFORE this call and then use
                // it AFTER.
                try browser.runMacrotasks();

                // Each call to this runs scheduled load events.
                try page.*.dispatchLoad();

                const http_active = http_client.active;
                const total_network_activity = http_active + http_client.intercepted;
                if (page.*._notified_network_almost_idle.check(total_network_activity <= 2)) {
                    page.*.notifyNetworkAlmostIdle();
                }
                if (page.*._notified_network_idle.check(total_network_activity == 0)) {
                    page.*.notifyNetworkIdle();
                }

                if (http_active == 0 and exit_when_done) {
                    // we don't need to consider http_client.intercepted here
                    // because exit_when_done is true, and that can only be
                    // the case when interception isn't possible.
                    if (comptime IS_DEBUG) {
                        std.debug.assert(http_client.intercepted == 0);
                    }

                    const is_event_done = switch (wait_until) {
                        .fixed => false,
                        .domcontentloaded => (page.*._load_state == .load or page.*._load_state == .complete),
                        .load => (page.*._load_state == .complete),
                        .networkidle => (page.*._load_state == .complete and http_active == 0),
                    };

                    var ms = blk: {
                        if (browser.hasBackgroundTasks()) {
                            // _we_ have nothing to run, but v8 is working on
                            // background tasks. We'll wait for them.
                            browser.waitForBackgroundTasks();
                            break :blk 20;
                        }

                        const next_task = browser.msToNextMacrotask();
                        if (next_task == null and is_event_done) {
                            return .done;
                        }
                        break :blk next_task orelse 20;
                    };

                    if (ms > ms_remaining) {
                        if (is_event_done) {
                            return .done;
                        }
                        // Same as above, except we have a scheduled task,
                        // it just happens to be too far into the future
                        // compared to how long we were told to wait.
                        if (!browser.hasBackgroundTasks()) {
                            if (is_event_done) return .done;
                        } else {
                            // _we_ have nothing to run, but v8 is working on
                            // background tasks. We'll wait for them.
                            browser.waitForBackgroundTasks();
                        }
                        ms = 20;
                    }

                    // We have a task to run in the not-so-distant future.
                    // You might think we can just sleep until that task is
                    // ready, but we should continue to run lowPriority tasks
                    // in the meantime, and that could unblock things. So
                    // we'll just sleep for a bit, and then restart our wait
                    // loop to see if anything new can be processed.
                    std.Thread.sleep(std.time.ns_per_ms * @as(u64, @intCast(@min(ms, 20))));
                } else {
                    // We're here because we either have active HTTP
                    // connections, or exit_when_done == false (aka, there's
                    // an cdp_socket registered with the http client).
                    // We should continue to run tasks, so we minimize how long
                    // we'll poll for network I/O.
                    var ms_to_wait = @min(200, browser.msToNextMacrotask() orelse 200);
                    if (ms_to_wait > 10 and browser.hasBackgroundTasks()) {
                        // if we have background tasks, we don't want to wait too
                        // long for a message from the client. We want to go back
                        // to the top of the loop and run macrotasks.
                        ms_to_wait = 10;
                    }
                    if (try http_client.tick(@min(ms_remaining, ms_to_wait)) == .cdp_socket) {
                        // data on a socket we aren't handling, return to caller
                        return .cdp_socket;
                    }
                }
            },
            .err => |err| {
                page.*._parse_state = .{ .raw_done = @errorName(err) };
                return err;
            },
            .raw_done => {
                if (exit_when_done) {
                    return .done;
                }
                // we _could_ http_client.tick(ms_to_wait), but this has
                // the same result, and I feel is more correct.
                return .no_page;
            },
        }

        const ms_elapsed = timer.lap() / 1_000_000;
        if (ms_elapsed >= ms_remaining) {
            return .done;
        }
        ms_remaining -= @intCast(ms_elapsed);
    }
}

pub fn scheduleNavigation(self: *Session, page: *Page) !void {
    const list = &self.queued_navigation;

    // Check if page is already queued
    for (list.items) |existing| {
        if (existing == page) {
            // Already queued
            return;
        }
    }

    return list.append(self.arena, page);
}

fn processQueuedNavigation(self: *Session) !void {
    const navigations = &self.queued_navigation;

    if (self.page.?._queued_navigation != null) {
        // This is both an optimization and a simplification of sorts. If the
        // root page is navigating, then we don't need to process any other
        // navigation. Also, the navigation for the root page and for a frame
        // is different enough that have two distinct code blocks is, imo,
        // better. Yes, there will be duplication.
        navigations.clearRetainingCapacity();
        return self.processRootQueuedNavigation();
    }

    const about_blank_queue = &self.queued_queued_navigation;
    defer about_blank_queue.clearRetainingCapacity();

    // First pass: process async navigations (non-about:blank)
    // These cannot cause re-entrant navigation scheduling
    for (navigations.items) |page| {
        const qn = page._queued_navigation.?;

        if (qn.is_about_blank) {
            // Defer about:blank to second pass
            try about_blank_queue.append(self.arena, page);
            continue;
        }

        self.processFrameNavigation(page, qn) catch |err| {
            log.warn(.page, "frame navigation", .{ .url = qn.url, .err = err });
        };
    }

    // Clear the queue after first pass
    navigations.clearRetainingCapacity();

    // Second pass: process synchronous navigations (about:blank)
    // These may trigger new navigations which go into queued_navigation
    for (about_blank_queue.items) |page| {
        const qn = page._queued_navigation.?;
        try self.processFrameNavigation(page, qn);
    }

    // Safety: Remove any about:blank navigations that were queued during the
    // second pass to prevent infinite loops
    var i: usize = 0;
    while (i < navigations.items.len) {
        const page = navigations.items[i];
        if (page._queued_navigation) |qn| {
            if (qn.is_about_blank) {
                log.warn(.page, "recursive about    blank", .{});
                _ = navigations.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

fn processFrameNavigation(self: *Session, page: *Page, qn: *QueuedNavigation) !void {
    lp.assert(page.parent != null, "root queued navigation", .{});

    const iframe = page.iframe.?;
    const parent = page.parent.?;

    page._queued_navigation = null;
    defer self.releaseArena(qn.arena);

    errdefer iframe._window = null;

    const parent_notified = page._parent_notified;
    if (parent_notified) {
        // we already notified the parent that we had loaded
        parent._pending_loads += 1;
    }

    const frame_id = page._frame_id;
    page.deinit(true);
    page.* = undefined;

    try Page.init(page, frame_id, self, parent);
    errdefer {
        for (parent.frames.items, 0..) |frame, i| {
            if (frame == page) {
                parent.frames_sorted = false;
                _ = parent.frames.swapRemove(i);
                break;
            }
        }
        if (parent_notified) {
            parent._pending_loads -= 1;
        }
        page.deinit(true);
    }

    page.iframe = iframe;
    iframe._window = page.window;

    page.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued frame navigation error", .{ .err = err });
        return err;
    };
}

fn processRootQueuedNavigation(self: *Session) !void {
    const current_page = &self.page.?;
    const frame_id = current_page._frame_id;

    // create a copy before the page is cleared
    const qn = current_page._queued_navigation.?;
    current_page._queued_navigation = null;

    defer self.arena_pool.release(qn.arena);

    // HACK
    // Mark as released in tracking BEFORE removePage clears the map.
    // We can't call releaseArena() because that would also return the arena
    // to the pool, making the memory invalid before we use qn.url/qn.opts.
    if (comptime IS_DEBUG) {
        if (self._arena_pool_leak_track.getPtr(@intFromPtr(qn.arena.ptr))) |found| {
            found.count = 0;
        }
    }

    self.removePage();

    self.page = @as(Page, undefined);
    const new_page = &self.page.?;
    try Page.init(new_page, frame_id, self, null);

    // Creates a new NavigationEventTarget for this page.
    try self.navigation.onNewPage(new_page);

    // start JS env
    // Inform CDP the main page has been created such that additional context for other Worlds can be created as well
    self.notification.dispatch(.page_created, new_page);

    new_page.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued navigation error", .{ .err = err });
        return err;
    };
}

pub fn nextFrameId(self: *Session) u32 {
    const id = self.frame_id_gen +% 1;
    self.frame_id_gen = id;
    return id;
}

pub fn nextPageId(self: *Session) u32 {
    const id = self.page_id_gen +% 1;
    self.page_id_gen = id;
    return id;
}

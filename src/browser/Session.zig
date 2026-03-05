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

const js = @import("js/js.zig");
const storage = @import("webapi/storage/storage.zig");
const Navigation = @import("webapi/navigation/Navigation.zig");
const History = @import("webapi/History.zig");

const Page = @import("Page.zig");
const Browser = @import("Browser.zig");
const Notification = @import("../Notification.zig");
const QueuedNavigation = Page.QueuedNavigation;

const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
const Session = @This();

browser: *Browser,
notification: *Notification,

queued_navigation: std.ArrayList(*QueuedNavigation),
// It's possible (but unlikely) that a queued navigation happens when we're
// processessing queued navigations (thank you WPT). This causes a lot of issues
// including possibly invalidating `queued_navigation` and endless loops.
// We use a double queue to avoid this.
processing_queued_navigation: bool,
queued_queued_navigation: std.ArrayList(*QueuedNavigation),

// Used to create our Inspector and in the BrowserContext.
arena: Allocator,

cookie_jar: storage.Cookie.Jar,
storage_shed: storage.Shed,

history: History,
navigation: Navigation,

page: ?Page,

frame_id_gen: u32,

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena = try browser.arena_pool.acquire();
    errdefer browser.arena_pool.release(arena);

    self.* = .{
        .page = null,
        .arena = arena,
        .history = .{},
        .frame_id_gen = 0,
        // The prototype (EventTarget) for Navigation is created when a Page is created.
        .navigation = .{ ._proto = undefined },
        .storage_shed = .{},
        .browser = browser,
        .queued_navigation = .{},
        .queued_queued_navigation = .{},
        .processing_queued_navigation = false,
        .notification = notification,
        .cookie_jar = storage.Cookie.Jar.init(allocator),
    };
}

pub fn deinit(self: *Session) void {
    if (self.page != null) {
        self.removePage();
    }
    self.cookie_jar.deinit();

    const browser = self.browser;
    self.storage_shed.deinit(browser.app.allocator);
    browser.arena_pool.release(self.arena);
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

    if (comptime IS_DEBUG) {
        log.debug(.browser, "remove page", .{});
    }
}

pub fn replacePage(self: *Session) !*Page {
    if (comptime IS_DEBUG) {
        log.debug(.browser, "replace page", .{});
    }

    lp.assert(self.page != null, "Session.replacePage null page", .{});

    var current = self.page.?;
    const frame_id = current._frame_id;
    const parent = current.parent;
    current.deinit(false);

    self.browser.env.memoryPressureNotification(.moderate);

    self.page = @as(Page, undefined);
    const page = &self.page.?;
    try Page.init(page, frame_id, self, parent);
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

pub fn findPage(self: *Session, frame_id: u32) ?*Page {
    const page = self.currentPage() orelse return null;
    return if (page._frame_id == frame_id) page else null;
}

pub fn wait(self: *Session, wait_ms: u32) WaitResult {
    var page = &(self.page orelse return .no_page);
    while (true) {
        const wait_result = self._wait(page, wait_ms) catch |err| {
            switch (err) {
                error.JsError => {}, // already logged (with hopefully more context)
                else => log.err(.browser, "session wait", .{
                    .err = err,
                    .url = page.url,
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

fn _wait(self: *Session, page: *Page, wait_ms: u32) !WaitResult {
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
        switch (page._parse_state) {
            .pre, .raw, .text, .image => {
                // The main page hasn't started/finished navigating.
                // There's no JS to run, and no reason to run the scheduler.
                if (http_client.active == 0 and exit_when_done) {
                    // haven't started navigating, I guess.
                    return .done;
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
                const ms_to_next_task = try browser.runMacrotasks();

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

                if (http_active == 0 and exit_when_done) {
                    // we don't need to consider http_client.intercepted here
                    // because exit_when_done is true, and that can only be
                    // the case when interception isn't possible.
                    if (comptime IS_DEBUG) {
                        std.debug.assert(http_client.intercepted == 0);
                    }

                    const ms: u64 = ms_to_next_task orelse blk: {
                        if (wait_ms - ms_remaining < 100) {
                            if (comptime builtin.is_test) {
                                return .done;
                            }
                            // Look, we want to exit ASAP, but we don't want
                            // to exit so fast that we've run none of the
                            // background jobs.
                            break :blk 50;
                        }

                        if (browser.hasBackgroundTasks()) {
                            // _we_ have nothing to run, but v8 is working on
                            // background tasks. We'll wait for them.
                            browser.waitForBackgroundTasks();
                            break :blk 20;
                        }

                        // No http transfers, no cdp extra socket, no
                        // scheduled tasks, we're done.
                        return .done;
                    };

                    if (ms > ms_remaining) {
                        // Same as above, except we have a scheduled task,
                        // it just happens to be too far into the future
                        // compared to how long we were told to wait.
                        return .done;
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
                    // We should continue to run lowPriority tasks, so we
                    // minimize how long we'll poll for network I/O.
                    var ms_to_wait = @min(200, ms_to_next_task orelse 200);
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
                page._parse_state = .{ .raw_done = @errorName(err) };
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

pub fn scheduleNavigation(self: *Session, qn: *QueuedNavigation) !void {
    const iframe = qn.iframe;
    const list = if (self.processing_queued_navigation) &self.queued_queued_navigation else &self.queued_navigation;
    for (list.items, 0..) |existing, i| {
        if (existing.iframe == iframe) {
            self.browser.arena_pool.release(existing.arena);
            list.items[i] = qn;
            return;
        }
    } else {
        return list.append(self.arena, qn);
    }
}

fn processQueuedNavigation(self: *Session) !void {
    const navigations = &self.queued_navigation;
    defer {
        navigations.clearRetainingCapacity();
        const copy = navigations.*;
        self.queued_navigation = self.queued_queued_navigation;
        self.queued_queued_navigation = copy;
    }

    if (self.page.?._queued_navigation != null) {
        // This is both an optimization and a simplification of sorts. If the
        // root page is navigating, then we don't need to process any other
        // navigation. Also, the navigation for the root page and for a frame
        // is different enough that have two distinct code blocks is, imo,
        // better. Yes, there will be duplication.
        return self.processRootQueuedNavigation();
    }
    self.processing_queued_navigation = true;
    defer self.processing_queued_navigation = false;

    const browser = self.browser;
    for (navigations.items) |qn| {
        const iframe = qn.iframe.?;
        const current_page = iframe._content_window.?._page; // Get the CURRENT page from iframe
        lp.assert(current_page.parent != null, "root queued navigation", .{});

        current_page._queued_navigation = null;
        defer browser.arena_pool.release(qn.arena);

        const parent = current_page.parent.?;
        errdefer iframe._content_window = null;

        if (current_page._parent_notified) {
            // we already notified the parent that we had loaded
            parent._pending_loads += 1;
        }

        const frame_id = current_page._frame_id;
        defer current_page.deinit(true);

        const new_page = try parent.arena.create(Page);
        try Page.init(new_page, frame_id, self, parent);
        errdefer new_page.deinit(true);

        new_page.iframe = iframe;
        iframe._content_window = new_page.window;

        new_page.navigate(qn.url, qn.opts) catch |err| {
            log.err(.browser, "queued frame navigation error", .{ .err = err });
            return err;
        };

        for (parent.frames.items, 0..) |p, i| {
            // Page.frames may or may not be sorted (depending on the
            // Page.frames_sorted flag). Putting this new page at the same
            // position as the one it's replacing is the simplest, safest and
            // probably most efficient option.
            if (p == current_page) {
                parent.frames.items[i] = new_page;
                break;
            }
        } else {
            lp.assert(false, "Existing frame not found", .{ .len = parent.frames.items.len });
        }
    }
}

fn processRootQueuedNavigation(self: *Session) !void {
    const current_page = &self.page.?;
    const frame_id = current_page._frame_id;

    // create a copy before the page is cleared
    const qn = current_page._queued_navigation.?;
    current_page._queued_navigation = null;
    defer self.browser.arena_pool.release(qn.arena);

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

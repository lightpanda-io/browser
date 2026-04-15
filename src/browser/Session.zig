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
const v8 = js.v8;
const storage = @import("webapi/storage/storage.zig");
const Navigation = @import("webapi/navigation/Navigation.zig");
const History = @import("webapi/History.zig");

const Page = @import("Page.zig");
pub const Runner = @import("Runner.zig");
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

// Identity tracking for the main world. All main world contexts share this,
// ensuring object identity works across same-origin frames.
identity: js.Identity = .{},

// Shared finalizer callbacks across all Identities. Keyed by Zig instance ptr.
// This ensures objects are only freed when ALL v8 wrappers are gone.
finalizer_callbacks: std.AutoHashMapUnmanaged(usize, *FinalizerCallback) = .empty,

// Pool for FinalizerCallback.Identity structs. These must survive page resets
// so V8 weak callbacks can validate the FC before dereferencing it.
fc_identity_pool: std.heap.MemoryPool(FinalizerCallback.Identity),

// Tracked global v8 objects that need to be released on cleanup.
// Lives at Session level so objects can outlive individual Identities.
globals: std.ArrayList(v8.Global) = .empty,

// Temporary v8 globals that can be released early. Key is global.data_ptr.
// Lives at Session level so objects holding Temps can outlive individual Identities.
temps: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

// Shared resources for all pages in this session.
// These live for the duration of the page tree (root + frames).
arena_pool: *ArenaPool,

page: ?Page,

// Double buffer so that, as we process one list of queued navigations, new entries
// are added to the separate buffer. This ensures that we don't end up with
// endless navigation loops AND that we don't invalidate the list while iterating
// if a new entry gets appended
queued_navigation_1: std.ArrayList(*Page),
queued_navigation_2: std.ArrayList(*Page),
// pointer to either queued_navigation_1 or queued_navigation_2
queued_navigation: *std.ArrayList(*Page),

// Temporary buffer for about:blank navigations during processing.
// We process async navigations first (safe from re-entrance), then sync
// about:blank navigations (which may add to queued_navigation).
queued_queued_navigation: std.ArrayList(*Page),

page_id_gen: u32 = 0,
frame_id_gen: u32 = 0,

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena_pool = browser.arena_pool;

    const arena = try arena_pool.acquire(.small, "Session");
    errdefer arena_pool.release(arena);

    const page_arena = try arena_pool.acquire(.large, "Session.page_arena");
    errdefer arena_pool.release(page_arena);

    self.* = .{
        .page = null,
        .arena = arena,
        .arena_pool = arena_pool,
        .page_arena = page_arena,
        .factory = Factory.init(page_arena),
        .history = .{},
        // The prototype (EventTarget) for Navigation is created when a Page is created.
        .navigation = .{ ._proto = undefined },
        .storage_shed = .{},
        .browser = browser,
        .queued_navigation = undefined,
        .queued_navigation_1 = .{},
        .queued_navigation_2 = .{},
        .queued_queued_navigation = .{},
        .notification = notification,
        .cookie_jar = storage.Cookie.Jar.init(allocator),
        .fc_identity_pool = .init(allocator),
    };
    self.queued_navigation = &self.queued_navigation_1;
}

pub fn deinit(self: *Session) void {
    if (self.page != null) {
        self.removePage();
    }
    self.cookie_jar.deinit();
    self.fc_identity_pool.deinit();

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

pub fn getArena(self: *Session, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.arena_pool.acquire(size_or_bucket, debug);
}

pub fn releaseArena(self: *Session, allocator: Allocator) void {
    self.arena_pool.release(allocator);
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
    defer self.browser.env.memoryPressureNotification(.moderate);

    self.identity.deinit();
    self.identity = .{};

    // Force cleanup all remaining finalized objects
    {
        var it = self.finalizer_callbacks.valueIterator();
        while (it.next()) |fc| {
            fc.*.deinit(self);
        }
        self.finalizer_callbacks = .empty;
    }

    {
        for (self.globals.items) |*global| {
            v8.v8__Global__Reset(global);
        }
        self.globals = .empty;
    }

    {
        var it = self.temps.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
        self.temps = .empty;
    }

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
        self.origins = .empty;
    }

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

    self.page = @as(Page, undefined);
    const page = &self.page.?;
    try Page.init(page, frame_id, self, null);
    return page;
}

pub fn currentPage(self: *Session) ?*Page {
    return &(self.page orelse return null);
}

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

pub fn runner(self: *Session, opts: Runner.Opts) !Runner {
    return Runner.init(self, opts);
}

pub fn scheduleNavigation(self: *Session, page: *Page) !void {
    const list = self.queued_navigation;

    // Check if page is already queued
    for (list.items) |existing| {
        if (existing == page) {
            // Already queued
            return;
        }
    }

    return list.append(self.arena, page);
}

pub fn processQueuedNavigation(self: *Session) !void {
    const navigations = self.queued_navigation;
    if (self.queued_navigation == &self.queued_navigation_1) {
        self.queued_navigation = &self.queued_navigation_2;
    } else {
        self.queued_navigation = &self.queued_navigation_1;
    }

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

    navigations.clearRetainingCapacity();

    // Second pass: process synchronous navigations (about:blank)
    // These may trigger new navigations which go into queued_navigation
    for (about_blank_queue.items) |page| {
        const qn = page._queued_navigation.?;
        try self.processFrameNavigation(page, qn);
    }

    // Safety: Remove any about:blank navigations that were queued during
    // processing to prevent infinite loops. New navigations have been queued
    // in the other buffer.
    const new_navigations = self.queued_navigation;
    var i: usize = 0;
    while (i < new_navigations.items.len) {
        const page = new_navigations.items[i];
        if (page._queued_navigation) |qn| {
            if (qn.is_about_blank) {
                log.warn(.page, "recursive about blank", .{});
                _ = self.queued_navigation.swapRemove(i);
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

// Every finalizable instance of Zig gets 1 FinalizerCallback registered in the
// session. This is to ensure that, if v8 doesn't finalize the value, we can
// release on page reset.
pub const FinalizerCallback = struct {
    arena: Allocator,
    session: *Session,
    resolved_ptr_id: usize,
    finalizer_ptr_id: usize,
    release_ref: *const fn (ptr_id: usize, session: *Session) void,

    // Linked list of Identities referencing this FC.
    identities: ?*Identity = null,
    // Count of active identities (for knowing when to clean up FC).
    identity_count: u8 = 0,

    // For every FinalizerCallback we'll have 1+ FinalizerCallback.Identity: one
    // for every identity that gets the instance. In most cases, that'll be 1.
    // Allocated from Session.fc_identity_pool so it survives page resets and
    // allows the weak callback to safely check the done flag.
    pub const Identity = struct {
        session: *Session,
        identity: *js.Identity,
        finalizer_ptr_id: usize,
        resolved_ptr_id: usize,
        next: ?*Identity = null,
        done: bool = false,
    };

    // Called during page reset to force cleanup regardless of identities.
    fn deinit(self: *FinalizerCallback, session: *Session) void {
        // Mark all identities as done so stale V8 weak callbacks
        // won't find the wrong FC if resolved_ptr_id is reused.
        var id = self.identities;
        while (id) |identity| {
            identity.done = true;
            id = identity.next;
        }
        self.release_ref(self.finalizer_ptr_id, session);
        session.releaseArena(self.arena);
    }
};

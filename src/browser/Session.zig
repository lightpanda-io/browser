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

const App = @import("../App.zig");

const js = @import("js/js.zig");
const v8 = js.v8;
const storage = @import("webapi/storage/storage.zig");
const Navigation = @import("webapi/navigation/Navigation.zig");
const History = @import("webapi/History.zig");

const Frame = @import("Frame.zig");
const Page = @import("Page.zig");
pub const Runner = @import("Runner.zig");
const Browser = @import("Browser.zig");
const Notification = @import("../Notification.zig");
const QueuedNavigation = Frame.QueuedNavigation;

const log = lp.log;
const ArenaPool = App.ArenaPool;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// A Session represents a browsing context group (cookie jar, session storage,
// navigation history) within a Browser. It hosts one Page at a time — the
// root Frame and all of its descendants — and is responsible for Page
// lifecycle (create, remove, replace on root navigation).
//
// Multiple concurrent Pages (e.g. an old Page retiring while a new provisional
// Page is loading) are not yet supported; see Page.zig for the intended
// direction.
const Session = @This();

browser: *Browser,
arena: Allocator,
history: History,
navigation: Navigation,
storage_shed: storage.Shed,
notification: *Notification,
cookie_jar: storage.Cookie.Jar,

// Shared allocator. Used by Session itself and borrowed by Pages.
arena_pool: *ArenaPool,

// Pool for FinalizerCallback.Identity structs. These must survive Page
// teardowns so V8 weak callbacks can validate the FC before dereferencing it.
fc_identity_pool: std.heap.MemoryPool(FinalizerCallback.Identity),

// The currently-active Page. Null when no Page exists (between removePage
// and createPage, or at startup).
page: ?Page,

// IDs. Kept at Session level so IDs can remain unique across Page replacements.
frame_id_gen: u32 = 0,
loader_id_gen: u32 = 0,

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena_pool = browser.arena_pool;

    const arena = try arena_pool.acquire(.small, "Session");
    errdefer arena_pool.release(arena);

    self.* = .{
        .page = null,
        .arena = arena,
        .arena_pool = arena_pool,
        .history = .{},
        // The prototype (EventTarget) for Navigation is created when a Frame is created.
        .navigation = .{ ._proto = undefined },
        .storage_shed = .{},
        .browser = browser,
        .notification = notification,
        .fc_identity_pool = .init(allocator),
        .cookie_jar = storage.Cookie.Jar.init(allocator),
    };
}

pub fn deinit(self: *Session) void {
    if (self.page != null) {
        self.removePage();
    }
    self.cookie_jar.deinit();
    self.fc_identity_pool.deinit();

    self.storage_shed.deinit(self.browser.app.allocator);
    self.arena_pool.release(self.arena);
}

// NOTE: the caller is not the owner of the returned value,
// the pointer on Frame is just returned as a convenience
pub fn createPage(self: *Session) !*Frame {
    lp.assert(self.page == null, "Session.createPage - page not null", .{});

    self.page = @as(Page, undefined);
    const page = &self.page.?;

    errdefer self.page = null;

    try Page.init(page, self, self.nextFrameId());
    const frame = &page.frame;

    // Creates a new NavigationEventTarget for this frame.
    try self.navigation.onNewFrame(frame);

    if (comptime IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }
    // start JS env
    // Inform CDP the main frame has been created such that additional context for other Worlds can be created as well
    self.notification.dispatch(.frame_created, frame);

    return frame;
}

pub fn removePage(self: *Session) void {
    lp.assert(self.page != null, "Session.removePage - page is null", .{});
    if (self.page.?.frame._script_manager.base.is_evaluating) {
        // Reentrant teardown from a CDP message drained inside syncRequest;
        // Session.deinit reclaims the page when the connection closes.
        return;
    }

    // Inform CDP the frame is going to be removed, allowing other worlds to remove themselves before the main one
    self.notification.dispatch(.frame_remove, .{});

    self.page.?.deinit(false);
    self.page = null;

    self.navigation.onRemoveFrame();

    // resetting frame_id_gen preserves previous behavior where removing the
    // root page returned us to a clean-slate state.
    self.frame_id_gen = 0;

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
    return self.page.?.getOrCreateOrigin(key_);
}

pub fn releaseOrigin(self: *Session, origin: *js.Origin) void {
    return self.page.?.releaseOrigin(origin);
}

pub fn replacePage(self: *Session) !*Frame {
    if (comptime IS_DEBUG) {
        log.debug(.browser, "replace page", .{});
    }

    lp.assert(self.page != null, "Session.replacePage null page", .{});
    const current = &self.page.?;
    lp.assert(current.frame.parent == null, "Session.replacePage with parent", .{});

    const frame_id = current.frame._frame_id;
    current.deinit(true);
    self.page = null;

    // Preserve prior behavior: frame_id_gen reset on root replacement so a
    // subsequent createPage starts from id 1. The captured frame_id is
    // passed into Page.init explicitly, so it isn't affected.
    self.frame_id_gen = 0;

    self.page = @as(Page, undefined);
    const page = &self.page.?;

    errdefer self.page = null;

    try Page.init(page, self, frame_id);
    return &page.frame;
}

pub fn currentPage(self: *Session) ?*Page {
    return &(self.page orelse return null);
}

pub fn currentFrame(self: *Session) ?*Frame {
    const page = self.currentPage() orelse return null;
    return &page.frame;
}

pub fn findFrameByFrameId(self: *Session, frame_id: u32) ?*Frame {
    const page = self.currentPage() orelse return null;
    return page.findFrameByFrameId(frame_id);
}

pub fn runner(self: *Session, opts: Runner.Opts) !Runner {
    return Runner.init(self, opts);
}

pub fn scheduleNavigation(self: *Session, frame: *Frame) !void {
    return self.page.?.scheduleNavigation(frame);
}

pub fn processQueuedNavigation(self: *Session) !void {
    const page = self.currentPage() orelse return;
    const navigations = page.queued_navigation;
    if (page.queued_navigation == &page.queued_navigation_1) {
        page.queued_navigation = &page.queued_navigation_2;
    } else {
        page.queued_navigation = &page.queued_navigation_1;
    }

    if (page.frame._queued_navigation != null) {
        // This is both an optimization and a simplification of sorts. If the
        // root frame is navigating, then we don't need to process any other
        // navigation. Also, the navigation for the root frame and for a frame
        // is different enough that have two distinct code blocks is, imo,
        // better. Yes, there will be duplication.
        navigations.clearRetainingCapacity();
        return self.processRootQueuedNavigation();
    }

    const about_blank_queue = &page.queued_queued_navigation;
    defer about_blank_queue.clearRetainingCapacity();

    // First pass: process async navigations (non-about:blank)
    for (navigations.items) |frame| {
        const qn = frame._queued_navigation.?;

        if (qn.is_about_blank) {
            // Defer about:blank to second pass
            try about_blank_queue.append(self.arena, frame);
            continue;
        }

        self.processFrameNavigation(frame, qn) catch |err| {
            log.warn(.frame, "frame navigation", .{ .url = qn.url, .err = err });
        };
    }

    navigations.clearRetainingCapacity();

    // Second pass: process synchronous navigations (about:blank)
    // These may trigger new navigations which go into queued_navigation
    for (about_blank_queue.items) |frame| {
        const qn = frame._queued_navigation.?;
        try self.processFrameNavigation(frame, qn);
    }

    // Safety: Remove any about:blank navigations that were queued during
    // processing to prevent infinite loops. New navigations have been queued
    // in the other buffer.
    const new_navigations = page.queued_navigation;
    var i: usize = 0;
    while (i < new_navigations.items.len) {
        const frame = new_navigations.items[i];
        if (frame._queued_navigation) |qn| {
            if (qn.is_about_blank) {
                log.warn(.frame, "recursive about blank", .{});
                _ = page.queued_navigation.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

fn processFrameNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    // Popups live on the Page as top-level browsing contexts without a
    // parent or iframe element. Their re-navigation path is simpler than
    // iframes — no parent bookkeeping to patch.
    if (frame.parent == null and frame.iframe == null) {
        return self.processPopupNavigation(frame, qn);
    }

    lp.assert(frame.parent != null, "root queued navigation", .{});

    const iframe = frame.iframe.?;
    const parent = frame.parent.?;

    frame._queued_navigation = null;
    defer self.releaseArena(qn.arena);

    errdefer iframe._window = null;

    const parent_notified = frame._parent_notified;
    if (parent_notified) {
        // we already notified the parent that we had loaded
        parent._pending_loads += 1;
    }

    const frame_id = frame._frame_id;
    const page = self.currentPage().?;
    frame.deinit(true);
    frame.* = undefined;

    errdefer {
        // If anything fails from this point on, frame.deinit will be called
        // and we need to remove the frame from the parent's frame list.
        for (parent.child_frames.items, 0..) |f, i| {
            if (f == frame) {
                parent.child_frames_sorted = false;
                _ = parent.child_frames.swapRemove(i);
                break;
            }
        }
    }

    try Frame.init(frame, frame_id, page, parent);
    errdefer {
        if (parent_notified) {
            parent._pending_loads -= 1;
        }
        frame.deinit(true);
    }

    frame.iframe = iframe;
    iframe._window = frame.window;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued frame navigation error", .{ .err = err });
        return err;
    };
}

// Re-navigates a popup Frame in place. The Frame pointer stays stable
// (scripts in the opener may hold a cached Window ref — though the Window
// object inside is replaced, matching how iframes behave on navigation).
fn processPopupNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    frame._queued_navigation = null;
    defer self.releaseArena(qn.arena);

    // Preserve popup identity fields. _name lives in the Page arena and
    // survives Frame.deinit; _opener is just a pointer.
    const saved_name = frame.window._name;
    const saved_opener = frame.window._opener;
    const frame_id = frame._frame_id;
    const page = self.currentPage().?;

    frame.deinit(true);
    frame.* = undefined;

    errdefer {
        // If re-init fails, drop from popups so we don't leave a corpse.
        for (page.popups.items, 0..) |p, i| {
            if (p == frame) {
                _ = page.popups.swapRemove(i);
                break;
            }
        }
    }

    try Frame.init(frame, frame_id, page, null);
    errdefer frame.deinit(true);

    frame.window._name = saved_name;
    frame.window._opener = saved_opener;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued popup navigation error", .{ .err = err });
        return err;
    };
}

fn processRootQueuedNavigation(self: *Session) !void {
    const current_frame = &self.page.?.frame;
    const frame_id = current_frame._frame_id;

    // create a copy before the frame is cleared
    const qn = current_frame._queued_navigation.?;
    current_frame._queued_navigation = null;

    defer self.arena_pool.release(qn.arena);

    // Dispatch frame_remove (same as removePage) then replace the Page
    // in-place, keeping the frame_id stable.
    self.notification.dispatch(.frame_remove, .{});
    self.page.?.deinit(true);
    self.page = null;

    self.navigation.onRemoveFrame();

    // Preserve prior behavior: the old resetFrameResources reset frame_id_gen.
    self.frame_id_gen = 0;

    self.page = @as(Page, undefined);
    const page = &self.page.?;

    errdefer self.page = null;

    try Page.init(page, self, frame_id);
    const new_frame = &page.frame;

    // Creates a new NavigationEventTarget for this frame.
    self.navigation.onNewFrame(new_frame) catch |err| {
        log.err(.browser, "createPage onNewNewFrame", .{ .err = err });
    };

    // start JS env
    // Inform CDP the main frame has been created such that additional context for other Worlds can be created as well
    self.notification.dispatch(.frame_created, new_frame);

    new_frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued navigation error", .{ .err = err });
        return err;
    };
}

pub fn nextFrameId(self: *Session) u32 {
    const id = self.frame_id_gen +% 1;
    self.frame_id_gen = id;
    return id;
}

pub fn nextLoaderId(self: *Session) u32 {
    const id = self.loader_id_gen +% 1;
    self.loader_id_gen = id;
    return id;
}

// Every finalizable instance of Zig gets 1 FinalizerCallback registered in the
// Page. This is to ensure that, if v8 doesn't finalize the value, we can
// release on Page teardown.
pub const FinalizerCallback = struct {
    page: *Page,
    arena: Allocator,
    resolved_ptr_id: usize,
    finalizer_ptr_id: usize,
    release_ref: *const fn (ptr_id: usize, page: *Page) void,

    // Linked list of Identities referencing this FC.
    identities: ?*Identity = null,
    // Count of active identities (for knowing when to clean up FC).
    identity_count: u8 = 0,

    // For every FinalizerCallback we'll have 1+ FinalizerCallback.Identity: one
    // for every identity that gets the instance. In most cases, that'll be 1.
    // Allocated from Session.fc_identity_pool so it survives Page teardowns and
    // allows the weak callback to safely check the done flag.
    pub const Identity = struct {
        session: *Session,
        // The Page that owns the FinalizerCallback this Identity references.
        // Only safe to dereference when `done == false`. When done is true,
        // the Page may have been torn down and this pointer is stale.
        page: *Page,
        identity: *js.Identity,
        finalizer_ptr_id: usize,
        resolved_ptr_id: usize,
        next: ?*Identity = null,
        done: bool = false,
    };

    // Called during Page teardown to force cleanup regardless of identities.
    pub fn deinit(self: *FinalizerCallback, page: *Page) void {
        // Mark all identities as done so stale V8 weak callbacks
        // won't find the wrong FC if resolved_ptr_id is reused.
        var id = self.identities;
        while (id) |identity| {
            identity.done = true;
            id = identity.next;
        }
        self.release_ref(self.finalizer_ptr_id, page);
        page.releaseArena(self.arena);
    }
};

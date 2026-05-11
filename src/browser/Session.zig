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
/// User-provided scripts to inject into header.
inject_scripts: []const []const u8 = &.{},

// Shared allocator. Used by Session itself and borrowed by Pages.
arena_pool: *ArenaPool,

// Pool for FinalizerCallback.Identity structs. These must survive Page
// teardowns so V8 weak callbacks can validate the FC before dereferencing it.
fc_identity_pool: std.heap.MemoryPool(FinalizerCallback.Identity),

// The currently-active Page
// flips this pointer.
_active: ?*Page = null,

// In-flight root navigation
_pending: ?*Page = null,

// IDs. Kept at Session level so IDs can remain unique across Page replacements.
frame_id_gen: u32 = 0,
loader_id_gen: u32 = 0,

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena_pool = browser.arena_pool;

    const arena = try arena_pool.acquire(.small, "Session");
    errdefer arena_pool.release(arena);

    self.* = .{
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
    if (self._pending != null) {
        self.discardPendingPage();
    }
    if (self._active != null) {
        self.removePage();
    }
    self.cookie_jar.deinit();

    // Force V8 to flush any remaining weak callbacks while
    // fc_identity_pool is still alive. Identity structs allocated from
    // this pool back V8 weak-callback parameters; freeing the pool first
    // would leave dangling pointers that segfault on the next GC.
    self.browser.env.memoryPressureNotification(.critical);
    self.fc_identity_pool.deinit();

    self.storage_shed.deinit(self.browser.app.allocator);
    self.arena_pool.release(self.arena);
}

// True iff there is an active Page. CDP / external callers should use this
// (or `currentPage()`) rather than poking at the underlying field.
pub fn hasPage(self: *const Session) bool {
    return self._active != null;
}

// Allocate and initialize a Page.
fn allocatePage(self: *Session, frame_id: u32) !*Page {
    const page = try self.browser.page_pool.create();
    errdefer self.browser.page_pool.destroy(page);

    try Page.init(page, self, frame_id);
    return page;
}

// Tear down and free a Page allocated via allocatePage.
fn destroyPage(self: *Session, page: *Page) void {
    page.deinit();
    self.browser.page_pool.destroy(page);
}

// Tear down the currently-active Page. Dispatches `frame_remove` first
// so CDP can clear inspector state while the OLD page is still walkable,
// then frees the slot and notifies Navigation. Resets `frame_id_gen` to
// match pre-pending-page behavior. Used by removePage and by the
// synthetic-nav path (replaceRootImmediate). Does NOT touch any pending
// page — callers handle that themselves.
//
// NOT a substitute for the careful 5-step sequence in commitPendingPage,
// which interleaves the OLD-page teardown with the pending-page promotion
// in a specific order.
fn tearDownActivePage(self: *Session) void {
    self.notification.dispatch(.frame_remove, .{});
    const page = self._active orelse {
        if (comptime IS_DEBUG) {
            lp.assert(false, "Session.tearDownActivePage - no active page", .{});
        }
        return;
    };
    self.destroyPage(page);
    self._active = null;
    self.navigation.onRemoveFrame();
    self.frame_id_gen = 0;
}

// Allocate a Page in a free slot, publish it as the active page, and
// dispatch `frame_created` so CDP creates fresh isolated-world V8
// contexts. Used by createPage and by the synthetic-nav path. Does NOT
// dispatch `frame_navigate` — the caller does that (or doesn't, for a
// blank initial page).
//
// On any failure after allocation, the errdefers roll back the Page
// and `active`, leaving the session pageless (the caller is responsible
// for any prior teardown of an old page).
fn installNewActivePage(self: *Session, frame_id: u32) !*Frame {
    const page = try self.allocatePage(frame_id);
    errdefer self.destroyPage(page);
    self._active = page;
    errdefer self._active = null;

    const frame = &page.frame;
    try self.navigation.onNewFrame(frame);
    // Inform CDP the main frame has been created such that additional
    // context for other Worlds can be created as well.
    self.notification.dispatch(.frame_created, frame);
    return frame;
}

// NOTE: the caller is not the owner of the returned value,
// the pointer on Frame is just returned as a convenience
pub fn createPage(self: *Session) !*Frame {
    lp.assert(self._active == null, "Session.createPage - page not null", .{});
    if (comptime IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }
    return self.installNewActivePage(self.nextFrameId());
}

pub fn removePage(self: *Session) void {
    const page = self._active orelse {
        lp.assert(false, "Session.removePage - page is null", .{});
    };

    if (page.frame.anyScriptEvaluating()) {
        // Reentrant teardown from a CDP message drained inside syncRequest;
        // either the page's own script (frame ScriptManager.is_evaluating)
        // or a Worker eval (Worker.loadInitialScript marks its
        // _worker_scope._script_manager.is_evaluating). Tearing down here
        // would free the arena/identity_map underneath the active eval.
        // Session.deinit reclaims the page when the connection closes.
        return;
    }

    // If a navigation is in flight, drop the pending Page first. Its
    // transfer was protected from abort to survive commitPendingPage's
    // teardown of the old page, but we are now permanently removing the
    // session's page state — the pending transfer should die with it.
    if (self._pending != null) {
        self.discardPendingPage();
    }
    self.tearDownActivePage();
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
    return self.currentPage().?.getOrCreateOrigin(key_);
}

pub fn releaseOrigin(self: *Session, origin: *js.Origin) void {
    self.currentPage().?.releaseOrigin(origin);
}

pub fn currentPage(self: *Session) ?*Page {
    return self._active;
}

pub fn pendingPage(self: *Session) ?*Page {
    return self._pending;
}

pub fn pendingOrCurrentFrame(self: *Session) ?*Frame {
    const page = self.pendingPage() orelse self.currentPage() orelse return null;
    return &page.frame;
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
    return self.currentPage().?.scheduleNavigation(frame);
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
    frame.deinit();
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
        frame.deinit();
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

    frame.deinit();
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
    errdefer frame.deinit();

    frame.window._name = saved_name;
    frame.window._opener = saved_opener;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued popup navigation error", .{ .err = err });
        return err;
    };
}

fn processRootQueuedNavigation(self: *Session) !void {
    const active = self._active orelse {
        lp.assert(false, "Session.processRootQueuedNavigation - no active page", .{});
    };
    const current_frame = &active.frame;

    // Detach the QueuedNavigation. Whether we keep it on the active frame
    // (synthetic path) or transfer it to the pending frame (HTTP path), the
    // current frame must no longer claim it.
    const qn = current_frame._queued_navigation.?;
    current_frame._queued_navigation = null;

    // Synthetic navigations (about:blank, blob:) commit instantly — no HTTP,
    // so there is no in-flight window to worry about. Use the optimized
    // immediate-swap path for them.
    const is_synthetic = qn.is_about_blank or std.mem.startsWith(u8, qn.url, "blob:");

    if (is_synthetic) {
        return self.replaceRootImmediate(current_frame._frame_id, qn);
    }

    // The qn arena is consumed here regardless of success — frame.navigate
    // dupes the URL into the page's own arena, so we can release the qn
    // arena as soon as navigate returns.
    defer self.arena_pool.release(qn.arena);

    return self.initiateRootNavigation(current_frame._frame_id, qn.url, qn.opts);
}

// Legacy immediate-swap path: tear down the active page and create a new one
// in its place before issuing the navigation. Used for synthetic navigations
// (about:blank, blob:) where there is no in-flight HTTP and therefore no
// "pending" window to span.
fn replaceRootImmediate(self: *Session, frame_id: u32, qn: *QueuedNavigation) !void {
    defer self.arena_pool.release(qn.arena);

    self.tearDownActivePage();
    const new_frame = try self.installNewActivePage(frame_id);

    new_frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued navigation error", .{ .err = err });
        return err;
    };
}

// Real HTTP root navigation: allocate a pending Page, leave the active Page
// alive, and dispatch the navigation HTTP request against the pending frame.
// The active Page (and its V8 context) stays addressable across the round-
// trip — Runtime.evaluate, DOM.*, etc. continue to operate on the OLD page
// until commitPendingPage swaps the pointer when response headers arrive.
pub fn initiateRootNavigation(self: *Session, frame_id: u32, url: [:0]const u8, opts: Frame.NavigateOpts) !void {
    self.discardPendingPage();

    const page = try self.allocatePage(frame_id);
    errdefer self.destroyPage(page);

    page._state = .pending;
    self._pending = page;
    errdefer self._pending = null;

    if (comptime IS_DEBUG) {
        log.debug(.browser, "initiate root navigation", .{ .url = url });
    }

    // No frame_created notification yet — CDP must not see the pending page
    // (no isolated worlds, no Target.* visibility). Both the pending main
    // world and the isolated worlds get registered with the V8 inspector at
    // commit, after frame_remove tears down the OLD page's context group.

    page.frame.navigate(url, opts) catch |err| {
        log.err(.browser, "pending navigation start", .{ .err = err, .url = url });
        return err;
    };
}

// Promote the pending Page to be the active Page. Called from
// frameHeaderDoneCallback when the in-flight pending root navigation's
// response headers arrive.
//
// Order matters here:
//   1. frame_remove dispatch — CDP's frameRemove resets the V8 inspector
//      context group (emits Runtime.executionContextsCleared) and clears
//      isolated world contexts plus the node_registry. The OLD page's
//      memory is still alive at this point (intentional: CDP teardown can
//      walk old-page state without UAF).
//   2. Pointer flip and _state = .active. session.page now points at the
//      pending page.
//   3. frame_created dispatch — CDP creates fresh isolated world contexts
//      against the new (now active) frame. While pending_page is still
//      non-null at this point, CDP's frameCreated handler skips its
//      frame_arena reset and captured_responses zeroing (the captured_
//      response for the request we are committing was just inserted by
//      onHttpResponseHeadersDone moments earlier and must survive).
//   4. pending_page = null. Order matters: step 3 reads it.
//   5. OLD Page.deinit + free LAST. Its frame.deinit calls
//      http_client.abortFrame(frame_id) on the frame_id that the OLD
//      page shares with the now-active pending page; the in-flight
//      navigation transfer (whose callback we are inside) is shielded
//      by protect_from_abort, which abortFrame's default .normal scope
//      honors. The caller clears the flag AFTER we return.
pub fn commitPendingPage(self: *Session) !void {
    const pending = self._pending orelse {
        lp.assert(false, "Session.commitPendingPage - no pending page", .{});
    };
    const old_active = self._active orelse {
        lp.assert(false, "Session.commitPendingPage - no active page", .{});
    };

    if (comptime IS_DEBUG) {
        log.debug(.browser, "commit pending page", .{});
    }

    // Step 1: clear the OLD page's CDP / V8 inspector state.
    self.notification.dispatch(.frame_remove, .{});
    self.navigation.onRemoveFrame();

    // Step 2: pointer flip. Page addresses are stable (heap-allocated),
    // so every self-pointer inside `pending` (window._frame,
    // document._frame, EventManager.frame, etc.) remains valid.
    self._active = pending;
    pending._state = .active;

    // Step 3: register the new page with CDP. `pending` is still set at
    // this point — CDP's frameCreated handler reads `pendingPage() != null`
    // to skip the captured_responses / frame_arena resets that would wipe
    // the in-flight response we just received.
    self.navigation.onNewFrame(&pending.frame) catch |err| {
        log.err(.browser, "commitPendingPage onNewFrame", .{ .err = err });
    };
    self.notification.dispatch(.frame_created, &pending.frame);

    // Step 4: `pending` = null AFTER frame_created so step 3 saw it.
    self._pending = null;

    // Step 5: tear down the OLD page LAST. Anything in steps 1-4 that
    // needed to walk the OLD page's state (CDP node_registry, inspector
    // context group, isolated worlds) has already done so. The OLD page's
    // frame.deinit calls http_client.abortFrame(frame_id) on the frame_id
    // shared with the pending page; the in-flight transfer survives via
    // protect_from_abort.
    self.destroyPage(old_active);
}

// Discard a pending Page without committing. Used for failure paths
// (HTTP error before commit, session deinit during pending, etc.). The
// active page is untouched.
pub fn discardPendingPage(self: *Session) void {
    const page = self._pending orelse return;

    if (comptime IS_DEBUG) {
        log.debug(.browser, "discard pending page", .{});
    }

    // Force abort all inflight queries.
    self.browser.http_client.abortFrame(page.frame._frame_id, .{ .scope = .full });

    self._pending = null;
    self.destroyPage(page);
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

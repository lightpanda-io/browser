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

const History = @import("webapi/History.zig");
const storage = @import("webapi/storage/storage.zig");
const IdbManager = @import("webapi/storage/idb/idb.zig").Manager;
const Navigation = @import("webapi/navigation/Navigation.zig");

const Page = @import("Page.zig");
const Frame = @import("Frame.zig");
const Browser = @import("Browser.zig");
pub const Runner = @import("Runner.zig");
const Notification = @import("../Notification.zig");
const QueuedNavigation = Frame.QueuedNavigation;
const SharedWorkerGlobalScope = @import("webapi/SharedWorkerGlobalScope.zig");

const log = lp.log;
const ArenaPool = App.ArenaPool;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// A Session represents a browsing context group (cookie jar, session storage,
// navigation history) within a Browser. It owns a set of live Pages — each a
// root Frame and all of its descendants — and is responsible for Page
// lifecycle (create, remove, replace on root navigation).

const Session = @This();

browser: *Browser,
arena: Allocator,
history: History,
navigation: Navigation,
storage_shed: storage.Shed,
// Per-origin IndexedDB engines
idb: IdbManager,
// Backs `globalThis.lp.*`; values pre-stringified so the prelude splices
// them in without re-encoding.
bridge_store: std.StringHashMapUnmanaged([]const u8) = .empty,
notification: *Notification,
cookie_jar: storage.Cookie.Jar,
/// User-provided scripts to inject into header.
inject_scripts: []const []const u8 = &.{},

// Shared allocator. Used by Session itself and borrowed by Pages.
arena_pool: *ArenaPool,

// All live top-level Pages. During a root navigation this transiently holds
// both the live page and its in-flight replacement.
pages: std.ArrayList(*Page) = .{},

// Live SharedWorkerGlobalScopes, keyed by "url\x00name", so every
// `new SharedWorker(url, name)` in the session connects to the same instance.
// Owned by the Page that creates it.
shared_workers: std.StringHashMapUnmanaged(*SharedWorkerGlobalScope) = .empty,

_page_destruction_queue: std.ArrayList(*Page) = .{},

// Round-robin cursor for fair page iteration (processQueuedNavigation)
_nav_cursor: usize = 0,

// Set by the agent script Runtime around one tool call so each `Page` handle's
// tools act on its own frame, not `pages[0]`. Null for all other callers.
// A frame id, not a pointer: a tool-triggered navigation commits a replacement
// Page mid-call, freeing the old Frame while keeping its frame id (see
// `commitPendingPage`).
_tool_frame_override: ?u32 = null,

// Loader IDs are scoped to the Session: each new BrowserContext gets a
// fresh counter. Frame IDs (`frame_id_gen`) live on `Browser` instead so
// CDP target IDs stay unique across BrowserContext lifecycle on a single
// connection (see `Browser.frame_id_gen` and issue #2472).
loader_id_gen: u32 = 0,

// configuration (or CDP command) to disable iframe loading
subframe_loading_enabled: bool = true,

// configuration (or CDP command) to disable Web Worker loading. When false,
// `new Worker(url)` returns a Worker object whose script is never fetched
// and never evaluated. Set from the `--disable-workers` CLI flag at
// session init; the LP.configureLoading CDP method can flip it per-session.
worker_loading_enabled: bool = true,

// Console.* capture for the `consoleLogs` tool, capped at `max_console_bytes`.
// Opt-in via `enableConsoleCapture`: plain CDP `serve` never drains it, so
// leaving the listener off keeps the buffer at zero bytes.
_console_messages: std.Io.Writer.Allocating,
_console_capture: bool = false,

// Opt-in fetch of external <link rel=stylesheet> resources. Defaults to
// false to preserve the current rendering-free fast path: drivers that
// don't need accurate visibility checks pay nothing. Set from the
// `--enable-external-stylesheets` CLI flag at session init; the
// LP.configureLoading CDP method can flip it per-session. When true,
// `Link.linkAddedCallback` routes to `Frame.loadExternalStylesheet`
// (synchronous fetch + parse + register on `document.styleSheets`).
load_external_stylesheets: bool = false,

/// Caller-supplied cancellation probe. `Runner._wait` polls it between
/// ticks; once `check` returns true the wait returns `error.Cancelled`.
/// The agent installs this so SIGINT can abort an in-flight tool call
/// (goto, search, waitForSelector, …) without sitting through the full
/// timeout.
cancel_hook: ?CancelHook = null,

// Download handling configured via the `Browser.setDownloadBehavior` CDP
// method (see issue #2701). When `download_behavior` is `.allow` or
// `.allow_and_name`, a navigation whose response carries
// `Content-Disposition: attachment` is written to `download_path` instead
// of being parsed as a page, and (when `download_events_enabled` is set)
// `Browser.downloadWillBegin` / `Browser.downloadProgress` events are emitted.
// `download_path` is duped into the Session arena.
download_behavior: DownloadBehavior = .deny,
download_path: ?[]const u8 = null,
download_events_enabled: bool = false,

pub const DownloadBehavior = enum {
    allow,
    allow_and_name,
    // The CDP `default` behavior is mapped to `deny`: we don't write downloads
    // to disk unless the driver explicitly opts in with `allow`/`allowAndName`.
    deny,
};

pub const CancelHook = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque) bool,
};

pub fn isCancelled(self: *const Session) bool {
    const hook = self.cancel_hook orelse return false;
    return hook.check(hook.context);
}

const max_console_bytes = 64 * 1024;

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
        .idb = IdbManager.init(allocator),
        .browser = browser,
        .notification = notification,
        .cookie_jar = storage.Cookie.Jar.init(allocator, notification),
        // CLI defaults; LP.configureLoading can flip these per-session.
        .subframe_loading_enabled = !browser.app.config.disableSubframes(),
        .worker_loading_enabled = !browser.app.config.disableWorkers(),
        ._console_messages = .init(allocator),
        .load_external_stylesheets = browser.app.config.enableExternalStylesheets(),
    };
    errdefer self._console_messages.deinit();
}

pub fn deinit(self: *Session) void {
    if (self._console_capture) {
        self.notification.unregister(.console_message, self);
    }

    self.closeAllPages();

    self.cookie_jar.deinit();

    self.browser.env.memoryPressureNotification(.critical);

    self.storage_shed.deinit(self.browser.app.allocator);
    self.idb.deinit();
    {
        const allocator = self.browser.app.allocator;
        var it = self.bridge_store.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self.bridge_store.deinit(allocator);
    }
    self._console_messages.deinit();
    self.arena_pool.release(self.arena);
}

/// Register the console listener so `drainConsoleMessages` returns output. Idempotent.
pub fn enableConsoleCapture(self: *Session) !void {
    if (self._console_capture) return;
    try self.notification.register(.console_message, self, onConsoleMessage);
    self._console_capture = true;
}

fn onConsoleMessage(ctx: *anyopaque, msg: *const Notification.ConsoleMessage) !void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const aw = &self._console_messages;
    const start = aw.written().len;
    if (start >= max_console_bytes) return;

    // Format into a scratch buffer sized to the remaining budget so a single
    // 10 MB `console.log` can't bust the cap before the post-hoc check fires.
    const remaining = max_console_bytes - start;
    var scratch_buf: [max_console_bytes]u8 = undefined;
    var scratch: std.Io.Writer = .fixed(scratch_buf[0..remaining]);
    appendConsoleMessageInner(&scratch, msg) catch {};
    aw.writer.writeAll(scratch.buffered()) catch {
        aw.shrinkRetainingCapacity(start);
    };
}

fn appendConsoleMessageInner(w: *std.Io.Writer, msg: *const Notification.ConsoleMessage) !void {
    try w.print("[{s}] ", .{@tagName(msg.type)});
    for (msg.values, 0..) |value, i| {
        if (i > 0) try w.writeAll(" ");
        try value.format(w);
    }
    try w.writeByte('\n');
}

/// Drains and clears the buffered console output. The returned slice is valid
/// until the next dispatched `console_message` reuses the backing storage,
/// so callers must consume or copy it before that happens.
pub fn drainConsoleMessages(self: *Session) []const u8 {
    const text = self._console_messages.written();
    self._console_messages.clearRetainingCapacity();
    return text;
}

pub fn processDestroyQueues(self: *Session) void {
    {
        const queue = self._page_destruction_queue.items;
        if (queue.len > 0) {
            for (queue) |page| {
                page.deinit();
                self.browser.page_pool.destroy(page);
            }
            self._page_destruction_queue.clearRetainingCapacity();
        }
    }
}

pub fn hasPage(self: *const Session) bool {
    return self.pages.items.len != 0;
}

// Allocate and initialize a Page.
fn allocatePage(self: *Session, frame_id: u32) !*Page {
    const page = try self.browser.page_pool.create();
    errdefer self.browser.page_pool.destroy(page);

    try Page.init(page, self, frame_id);
    return page;
}

// Tear down and free a Page allocated via allocatePage.
fn queuePageDestruction(self: *Session, page: *Page) void {
    self._page_destruction_queue.append(self.arena, page) catch @panic("OOM");
}

fn retire(self: *Session, page: *Page) void {
    if (page.replaces) |live| {
        // page is being destroyed, if it was replacing a page, then update that
        // page's replacement to keep replaces<->replacement consistent.
        live.replacement = null;
    }

    if (page.replacement) |replacement| {
        // page is being destroyed, also detroy its replacement
        self.discardPendingPage(replacement);
    }

    page.frame.abortTransfers();
    self.removePageFromList(page);
    self.queuePageDestruction(page);
}

fn removePageFromList(self: *Session, page: *Page) void {
    if (std.mem.indexOfScalar(*Page, self.pages.items, page)) |i| {
        _ = self.pages.swapRemove(i);
    }
}

// Tear down the currently-active Page. Dispatches `frame_remove` first
// so CDP can clear inspector state while the OLD page is still walkable,
// then frees the slot and notifies Navigation. Used by removePage and
// by the synthetic-nav path (replaceRootImmediate). Does NOT touch any
// pending page — callers handle that themselves.
//
// Frame IDs are NOT reset here — the counter lives on `Browser` and is
// monotonic for the lifetime of the CDP connection so target IDs stay
// unique (issue #2472). The previous reset-to-zero behaviour was
// invisible within a single Session/BrowserContext (the next
// `installNewActivePage` was usually called with the old frame's
// explicit `frame_id`, see `replaceRootImmediate`) but caused
// `Duplicate target FID-...` collisions when a new BrowserContext
// allocated its first page after dispose.
//
// NOT a substitute for the careful 5-step sequence in commitPendingPage,
// which interleaves the OLD-page teardown with the pending-page promotion
// in a specific order.
fn tearDownPage(self: *Session, page: *Page) void {
    self.notification.dispatch(.frame_remove, .{});
    self.retire(page);
    self.navigation.onRemoveFrame();
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
    errdefer self.queuePageDestruction(page);

    try self.pages.append(self.arena, page);
    errdefer _ = self.pages.pop();

    const frame = &page.frame;
    try self.navigation.onNewFrame(frame);
    // Inform CDP the main frame has been created such that additional
    // context for other Worlds can be created as well.
    self.notification.dispatch(.frame_created, frame);
    return frame;
}

pub fn createPage(self: *Session) !PageHandle {
    // Drain any pending Page deinits now, while we're at a known-safe point
    self.processDestroyQueues();

    if (comptime IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }

    const frame_id = self.nextFrameId();
    _ = try self.installNewActivePage(frame_id);

    return .{ .session = self, .frame_id = frame_id };
}

// Tear down the live page for `frame_id` and any in-flight replacement.
pub fn closePage(self: *Session, frame_id: u32) void {
    const live = self.livePage(frame_id) orelse return;

    // If a navigation is in flight, drop the pending Page first. Its
    // transfer was protected from abort to survive commitPendingPage's
    // teardown of the old page, but we are now permanently removing the
    // page state — the pending transfer should die with it.
    if (self.replacementOf(live)) |pending| {
        self.discardPendingPage(pending);
    }
    self.tearDownPage(live);
}

// Does not dispatch notifications. Used in session.deinit() and used in tests.
// We queue then process so that there is a single place (processDestroyQueues)
// where pages get destroyed.
pub fn closeAllPages(self: *Session) void {
    self._page_destruction_queue.ensureUnusedCapacity(self.arena, self.pages.items.len) catch @panic("OOM");
    for (self.pages.items) |page| {
        page.frame.abortTransfers();
        self._page_destruction_queue.appendAssumeCapacity(page);
    }
    self.pages.clearRetainingCapacity();
    self.processDestroyQueues();
}

pub fn getArena(self: *Session, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.arena_pool.acquire(size_or_bucket, debug);
}

pub fn releaseArena(self: *Session, allocator: Allocator) void {
    self.arena_pool.release(allocator);
}

// The live page for a top-level browsing context, by its root frame id.
pub fn livePage(self: *Session, frame_id: u32) ?*Page {
    for (self.pages.items) |page| {
        if (page.frame._frame_id == frame_id) {
            // If this page is replacing another page, then other page is
            // considered the "live" on. Only once this page is committed will
            // that swap.
            return page.replaces orelse page;
        }
    }
    return null;
}

pub fn pendingOrLivePage(self: *Session, frame_id: u32) ?*Page {
    for (self.pages.items) |page| {
        if (page.frame._frame_id == frame_id) {
            return page.replacement orelse page;
        }
    }
    return null;
}

// The in-flight replacement for `page`
pub fn replacementOf(self: *Session, page: *Page) ?*Page {
    const replacement = page.replacement;

    if (comptime IS_DEBUG) {
        // quick check to make sure our replacement <=> replaces link is in sync
        var found: ?*Page = null;
        for (self.pages.items) |p| {
            if (p.replaces == page) {
                found = p;
                break;
            }
        }
        std.debug.assert(found == replacement);
    }
    return replacement;
}

// DEPRECATED.
// Needed by Runner so long as Runner is largel single-page driven.
// Ultimately the goal is that runner is full multi-page, but during this
// transition to multi-page sessions, we maintain the idea that one page is
// the "main" page.
pub fn primaryPage(self: *Session) ?PageHandle {
    if (self.pages.items.len == 0) {
        return null;
    }
    const page = self.pages.items[0];
    if (comptime IS_DEBUG) {
        std.debug.assert(page.replaces == null);
    }
    return .{ .session = self, .frame_id = page.frame._frame_id };
}

// DEPRECATED. Exists during our transition to multi-page sessions.
pub fn currentFrame(self: *Session) ?*Frame {
    if (self._tool_frame_override) |frame_id| {
        // No pages[0] fallthrough: the override targets one specific page.
        return self.findFrameByFrameId(frame_id);
    }
    if (self.pages.items.len == 0) {
        return null;
    }
    const page = self.pages.items[0];
    if (comptime IS_DEBUG) {
        std.debug.assert(page.replaces == null);
    }
    return &page.frame;
}

/// See `_tool_frame_override`. Pass null to clear.
pub fn setToolFrameOverride(self: *Session, frame_id: ?u32) void {
    self._tool_frame_override = frame_id;
}

// Multi-page aware: frame ids are globally unique (monotonic on `Browser`).
// First we find the "live" page for a frame, then we search every nested
// frame within that page.
pub fn findFrameByFrameId(self: *Session, frame_id: u32) ?*Frame {
    if (self.livePage(frame_id)) |page| {
        return &page.frame;
    }
    for (self.pages.items) |page| {
        if (page.findFrameByFrameId(frame_id)) |frame| {
            return frame;
        }
    }
    return null;
}

pub fn runner(self: *Session, opts: Runner.Opts) Runner {
    return Runner.init(self, opts);
}

/// Page transfers run on the session thread's curl multi; left unserviced
/// while the frontend waits on input they die on curl's wall-clock timeout.
/// Returns how long the caller may block before pumping again.
pub fn idleSlice(self: *Session) u31 {
    const quiet_ms = 250;
    self.processDestroyQueues();

    if (self.pages.items.len == 0) {
        // no page, we don't want the watchdog to kill us.
        self.browser.http_client.heartbeat.disarm();
        return quiet_ms;
    }
    const page = self.pages.items[0];

    var r = self.runner(.{});
    const result = r.tickForFrame(page.frame._frame_id, 25, .{ .until = .done }) catch return quiet_ms;
    return switch (result) {
        .done => quiet_ms,
        .ok => |next_ms| @intCast(@min(next_ms, quiet_ms)),
    };
}

pub fn scheduleNavigation(_: *Session, frame: *Frame) !void {
    return frame._page.scheduleNavigation(frame);
}

// Drain one page's queued navigations and return whether any page had work.
// Processing a root navigation mutates self.pages, so it's safer to do this
// just once, signal the caller, and have them call again. We use a cursor
// to prevent one page from starving the rest.
pub fn processQueuedNavigation(self: *Session) !bool {
    const pages = self.pages.items;
    if (pages.len == 0) {
        return false;
    }

    var i = self._nav_cursor;
    if (i >= pages.len) {
        i = 0;
    }

    for (0..pages.len) |_| {
        const page = pages[i];

        i += 1;
        if (i == pages.len) {
            i = 0;
        }

        if (page.queued_navigation.items.len != 0) {
            // i was already incremented (and wrapped) to the "next" page
            self._nav_cursor = i;
            try self.processPageQueuedNavigation(page);
            return true;
        }
    }
    return false;
}

fn processPageQueuedNavigation(self: *Session, page: *Page) !void {
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
        return self.processRootQueuedNavigation(page);
    }

    const about_blank_queue = &page.queued_queued_navigation;
    defer about_blank_queue.clearRetainingCapacity();

    // First pass: process async navigations (non-about:blank)
    for (navigations.items) |frame| {
        const qn = frame._queued_navigation orelse {
            // Was previously an assert; downgraded so prod can recover, but
            // kept at warn so the invariant violation isn't silently lost.
            log.warn(.frame, "skipped null queued nav", .{});
            continue;
        };

        if (qn.is_about_blank) {
            // Defer about:blank to second pass
            try about_blank_queue.append(self.arena, frame);
            continue;
        }

        // qn is invalid after this
        self.processFrameNavigation(frame, qn) catch {
            // already logged
        };
    }

    navigations.clearRetainingCapacity();

    // Second pass: process synchronous navigations (about:blank)
    // These may trigger new navigations which go into queued_navigation.
    // Mirror the first pass: a failure on one frame must not orphan the
    // rest of the queue (the `defer clearRetainingCapacity` would wipe
    // siblings whose _queued_navigation stays set).
    for (about_blank_queue.items) |frame| {
        const qn = frame._queued_navigation orelse {
            // Was previously an assert; downgraded so prod can recover, but
            // kept at warn so the invariant violation isn't silently lost.
            log.warn(.frame, "skipped null queued nav", .{});
            continue;
        };
        self.processFrameNavigation(frame, qn) catch |err| {
            log.warn(.frame, "frame navigation", .{ .url = qn.url, .err = err });
        };
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
    frame._queued_navigation = null;
    defer self.releaseArena(qn.arena);

    // A popup whose window was close()'d is parked in page.closed_frames and
    // torn down at Page.deinit. It must never be navigated. This navigation
    // can happen _after_ window.close() has been called (because JS can do
    // anything with that window), so the safest place to prevent navigation
    // from happening is here.
    if (frame.window._closed) {
        return;
    }

    self._processFrameNavigation(frame, qn) catch |err| {
        log.warn(.frame, "frame navigation", .{ .url = qn.url, .err = err });
        return err;
    };
}

fn _processFrameNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    // Popups live on the Page as top-level browsing contexts without a
    // parent or iframe element. Their re-navigation path is simpler than
    // iframes — no parent bookkeeping to patch.
    if (frame.parent == null and frame.iframe == null) {
        return self.processPopupNavigation(frame, qn);
    }

    lp.assert(frame.parent != null, "root queued navigation", .{});

    const iframe = frame.iframe.?;
    const parent = frame.parent.?;

    errdefer iframe._window = null;

    // was the previous navigation of this frame delaying the paren't load event?
    const was_delaying = frame._delays_parent_load and !frame._parent_notified;

    // we weren't delaying the parent' load navigation, but now we should
    const starts_delaying = !was_delaying and !iframe.isLazyLoading();

    if (starts_delaying) {
        parent._pending_loads += 1;
    }

    const frame_id = frame._frame_id;
    const reuse_window = frame.window;
    const page = frame._page;
    frame.js.detachGlobal();
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

    try Frame.init(frame, frame_id, page, .{ .parent = parent, .reuse_window = reuse_window });
    errdefer {
        if (starts_delaying) {
            parent._pending_loads -= 1;
        }
        frame.deinit();
    }

    frame.iframe = iframe;
    // If we transition from was_delaying to !starts_delaying, we could potentially
    // call `parent._pending_loads -= 1;` but it's hard to reason through the
    // edge cases. So instead we carry it over, at worse delaying the parent's load
    // in the very unlikely case that the iframe was switch from non-lazy to lazy.
    frame._delays_parent_load = was_delaying or starts_delaying;
    iframe._window = frame.window;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued frame navigation error", .{ .err = err });
        return err;
    };
}

// Re-navigates a popup Frame in place. Both the Frame pointer and its Window
// stay stable across the re-init, so a cached `window.open()` return value keeps
// a valid `.location` instead of dangling against the freed one.
fn processPopupNavigation(_: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    // Preserve popup identity fields. _name lives in the Page arena and
    // survives Frame.deinit; _opener is just a pointer.

    const reuse_window = frame.window;
    const saved_name = reuse_window._name;
    const saved_opener = reuse_window._opener;
    const frame_id = frame._frame_id;
    const page = frame._page;

    frame.js.detachGlobal();
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

    try Frame.init(frame, frame_id, page, .{ .reuse_window = reuse_window });
    errdefer frame.deinit();

    frame.window._name = saved_name;
    frame.window._opener = saved_opener;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued popup navigation error", .{ .err = err });
        return err;
    };
}

fn processRootQueuedNavigation(self: *Session, page: *Page) !void {
    const current_frame = &page.frame;

    // Detach the QueuedNavigation. Whether we keep it on the active frame
    // (synthetic path) or transfer it to the pending frame (HTTP path), the
    // current frame must no longer claim it.
    const qn = current_frame._queued_navigation.?;
    current_frame._queued_navigation = null;

    // Synthetic navigations (about:blank, blob:) commit instantly — no HTTP,
    // so there is no in-flight window to worry about. Use the optimized
    // immediate-swap path for them.
    const is_synthetic = qn.is_about_blank or std.mem.startsWith(u8, qn.url, "blob:");

    // The qn arena is consumed here regardless of success — frame.navigate
    // dupes the URL into the page's own arena, so we can release the qn
    // arena as soon as navigate returns.
    defer self.arena_pool.release(qn.arena);

    if (is_synthetic) {
        return self.replaceRootImmediate(current_frame._frame_id, qn.url, qn.opts);
    }
    return self.initiateRootNavigation(current_frame._frame_id, qn.url, qn.opts);
}

// Immediate-swap path for synthetic navigations (about:blank, blob:): there is
// no in-flight HTTP and therefore no "pending" window to span — and no
// frameHeaderDoneCallback to commit a pending Page. Tear down the active page
// and create a new one in its place, then navigate it. Reached from both the
// queued-navigation path (processRootQueuedNavigation) and the CDP entry point
// (initiateRootNavigation); each caller owns any arena tied to `url`/`opts`.
fn replaceRootImmediate(self: *Session, frame_id: u32, url: [:0]const u8, opts: Frame.NavigateOpts) !void {
    if (self.livePage(frame_id)) |page| {
        self.tearDownPage(page);
    } else if (comptime IS_DEBUG) {
        lp.assert(false, "Session.replaceRootImmediate - no live page", .{});
    }
    const new_frame = try self.installNewActivePage(frame_id);

    new_frame.navigate(url, opts) catch |err| {
        log.err(.browser, "synthetic navigation error", .{ .err = err, .url = url });
        return err;
    };
}

// Real HTTP root navigation: allocate a pending Page, leave the active Page
// alive, and dispatch the navigation HTTP request against the pending frame.
// The active Page (and its V8 context) stays addressable across the round-
// trip — Runtime.evaluate, DOM.*, etc. continue to operate on the OLD page
// until commitPendingPage swaps the pointer when response headers arrive.
pub fn initiateRootNavigation(self: *Session, frame_id: u32, url: [:0]const u8, opts: Frame.NavigateOpts) !void {
    const live = self.livePage(frame_id) orelse {
        lp.assert(false, "Session.initiateRootNavigation - no live page", .{});
    };

    // Re-navigation before a previous root nav committed: drop the outstanding
    // replacement so `replaces` stays a single link, never a chain.
    if (self.replacementOf(live)) |old_replacement| {
        self.discardPendingPage(old_replacement);
    }

    // Synthetic navigations (about:blank, blob:) have no HTTP round-trip and
    // therefore no frameHeaderDoneCallback to commit a pending Page. Swap the
    // active Page immediately instead of allocating a pending one that would
    // never be promoted, leaving the previous document in place (issue #2363).
    if (std.mem.eql(u8, "about:blank", url) or std.mem.startsWith(u8, url, "blob:")) {
        return self.replaceRootImmediate(frame_id, url, opts);
    }

    const page = try self.allocatePage(frame_id);
    errdefer self.queuePageDestruction(page);

    // Reuses `live`'s frame_id: the replacement IS the same browsing context.
    // `replaces` keeps `live` addressable until commit; the `replacement`
    // back-pointer is its inverse
    page.replaces = live;
    live.replacement = page;

    errdefer live.replacement = null;
    try self.pages.append(self.arena, page);
    errdefer _ = self.pages.pop();

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

// Promote a pending replacement Page to be the live Page.
// Called from frameHeaderDoneCallback, aka when we get the headers, of the
// replacement page.
//
// Order matters here:
//   1. frame_remove dispatch — CDP's frameRemove resets the V8 inspector
//      context group (emits Runtime.executionContextsCleared) and clears
//      isolated world contexts plus the node_registry. OLD is still the live
//      page and its memory is alive (intentional: CDP teardown can walk
//      old-page state without UAF).
//   2. frame_created dispatch — CDP creates fresh isolated world contexts
//      against the new frame. `replacement.replaces` is still set, so the
//      session still reports an in-flight nav and CDP's frameCreated skips
//      its frame_arena reset and captured_responses zeroing (the captured
//      response for the request we are committing was just inserted by
//      onHttpResponseHeadersDone moments earlier and must survive).
//   3. Promote: clear `replaces` and unlink OLD from `pages`, so
//      `currentFrame()` / `livePage()` now resolve to `replacement`. Done AFTER
//      step 2 so the in-commit signal (replaces != null) survives the dispatch
//      — this is why no separate "committing" flag is needed.
//   4. Tear down OLD last.
pub fn commitPendingPage(self: *Session, replacement: *Page) !void {
    const old = replacement.replaces orelse {
        lp.assert(false, "Session.commitPendingPage - page has no replaces", .{});
    };

    if (comptime IS_DEBUG) {
        log.debug(.browser, "commit pending page", .{});
    }

    // Step 1: clear the OLD page's CDP / V8 inspector state while it is still
    // walkable (node_registry, inspector context group, isolated worlds). OLD
    // is still the live page (index 0); its memory stays alive until step 4.
    self.notification.dispatch(.frame_remove, .{});
    self.navigation.onRemoveFrame();

    // Step 2: register the new page with CDP. `replacement.replaces` is still
    // set, so the session still reports an in-flight nav and CDP's frameCreated
    // skips the captured_responses / frame_arena reset that would wipe the
    // response we just received.
    self.navigation.onNewFrame(&replacement.frame) catch |err| {
        log.err(.browser, "commitPendingPage onNewFrame", .{ .err = err });
    };
    self.notification.dispatch(.frame_created, &replacement.frame);

    // Step 3: promote — clear `replaces` and unlink OLD so  `livePage()`
    // resolve to `replacement` (both share OLD's frame_id). OLD stays allocated
    // (torn down next) but is no longer the addressable live page.

    old.replacement = null;
    replacement.replaces = null;
    self.removePageFromList(old);

    // Step 4: tear down the OLD page LAST. Anything in steps 1-3 that needed to
    // walk the OLD page's state has already done so. Kill any remaining
    // transfers/websockets synchronously before queuing for deferred destroy —
    // otherwise a still-inflight transfer firing its done_callback after this
    // point would re-enter against the now-live `replacement` and trip a
    // half-torn-down session.
    old.frame.abortTransfers();
    self.queuePageDestruction(old);
}

// Discard a pending Page without committing. Used for failure paths
// (HTTP error before commit, session deinit during pending, etc.). The
// active page is untouched.
pub fn discardPendingPage(self: *Session, replacement: *Page) void {
    if (comptime IS_DEBUG) {
        log.debug(.browser, "discard pending page", .{});
    }

    // Force abort all inflight queries (HTTP + WS) and queue for deferred
    // destroy. The live page it was replacing is untouched.
    self.retire(replacement);
}

// Frame IDs come from `Browser` (per-CDP-connection scope), not
// `Session` (per-BrowserContext). Kept as a Session method so existing
// callers (Frame, Worker) don't have to thread a Browser pointer.
pub fn nextFrameId(self: *Session) u32 {
    return self.browser.nextFrameId();
}

pub fn nextLoaderId(self: *Session) u32 {
    const id = self.loader_id_gen +% 1;
    self.loader_id_gen = id;
    return id;
}

// A stable, navigation-safe reference to a top-level browsing context (what
// `openPage` opens).
pub const PageHandle = struct {
    frame_id: u32,
    session: *Session,

    pub fn frame(self: PageHandle) ?*Frame {
        return &(self.page() orelse return null).frame;
    }

    pub fn page(self: PageHandle) ?*Page {
        return self.session.livePage(self.frame_id);
    }

    pub fn inCommit(self: PageHandle) bool {
        const live = self.page() orelse return false;
        return self.session.replacementOf(live) != null;
    }

    pub fn close(self: PageHandle) void {
        self.session.closePage(self.frame_id);
    }

    pub fn navigate(self: PageHandle, request_url: [:0]const u8, opts: Frame.NavigateOpts) !void {
        const f = self.frame() orelse return error.FrameNotLoaded;
        return f.navigate(request_url, opts);
    }
};

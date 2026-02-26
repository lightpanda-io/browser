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
const JS = @import("js/js.zig");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const IS_DEBUG = builtin.mode == .Debug;

const log = @import("../log.zig");

const App = @import("../App.zig");
const String = @import("../string.zig").String;

const Mime = @import("Mime.zig");
const Factory = @import("Factory.zig");
const Session = @import("Session.zig");
const EventManager = @import("EventManager.zig");
const ScriptManager = @import("ScriptManager.zig");

const Parser = @import("parser/Parser.zig");

const URL = @import("URL.zig");
const Blob = @import("webapi/Blob.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const CData = @import("webapi/CData.zig");
const Element = @import("webapi/Element.zig");
const HtmlElement = @import("webapi/element/Html.zig");
const Window = @import("webapi/Window.zig");
const Location = @import("webapi/Location.zig");
const Document = @import("webapi/Document.zig");
const ShadowRoot = @import("webapi/ShadowRoot.zig");
const Performance = @import("webapi/Performance.zig");
const Screen = @import("webapi/Screen.zig");
const VisualViewport = @import("webapi/VisualViewport.zig");
const PerformanceObserver = @import("webapi/PerformanceObserver.zig");
const MutationObserver = @import("webapi/MutationObserver.zig");
const IntersectionObserver = @import("webapi/IntersectionObserver.zig");
const CustomElementDefinition = @import("webapi/CustomElementDefinition.zig");
const storage = @import("webapi/storage/storage.zig");
const PageTransitionEvent = @import("webapi/event/PageTransitionEvent.zig");
const NavigationKind = @import("webapi/navigation/root.zig").NavigationKind;
const KeyboardEvent = @import("webapi/event/KeyboardEvent.zig");

const Http = App.Http;
const Net = @import("../Net.zig");
const ArenaPool = App.ArenaPool;

const timestamp = @import("../datetime.zig").timestamp;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

const WebApiURL = @import("webapi/URL.zig");
const GlobalEventHandlersLookup = @import("webapi/global_event_handlers.zig").Lookup;

var default_url = WebApiURL{ ._raw = "about:blank" };
pub var default_location: Location = Location{ ._url = &default_url };

pub const BUF_SIZE = 1024;

const Page = @This();

// This is the "id" of the frame. It can be re-used from page-to-page, e.g.
// when navigating.
id: u32,

_session: *Session,

_event_manager: EventManager,

_parse_mode: enum { document, fragment, document_write } = .document,

// See Attribute.List for what this is. TL;DR: proper DOM Attribute Nodes are
// fat yet rarely needed. We only create them on-demand, but still need proper
// identity (a given attribute should return the same *Attribute), so we do
// a look here. We don't store this in the Element or Attribute.List.Entry
// because that would require additional space per element / Attribute.List.Entry
// even thoug we'll create very few (if any) actual *Attributes.
_attribute_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute) = .empty,

// Same as _atlribute_lookup, but instead of individual attributes, this is for
// the return of elements.attributes.
_attribute_named_node_map_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute.NamedNodeMap) = .empty,

// Lazily-created style, classList, and dataset objects. Only stored for elements
// that actually access these features via JavaScript, saving 24 bytes per element.
_element_styles: Element.StyleLookup = .empty,
_element_datasets: Element.DatasetLookup = .empty,
_element_class_lists: Element.ClassListLookup = .empty,
_element_rel_lists: Element.RelListLookup = .empty,
_element_shadow_roots: Element.ShadowRootLookup = .empty,
_node_owner_documents: Node.OwnerDocumentLookup = .empty,
_element_assigned_slots: Element.AssignedSlotLookup = .empty,
_element_scroll_positions: Element.ScrollPositionLookup = .empty,
_element_namespace_uris: Element.NamespaceUriLookup = .empty,

/// Lazily-created inline event listeners (or listeners provided as attributes).
/// Avoids bloating all elements with extra function fields for rare usage.
///
/// Use this when a listener provided like this:
///
/// ```js
/// img.onload = () => { ... };
/// ```
///
/// Its also used as cache for such cases after lazy evaluation:
///
/// ```html
/// <img onload="(() => { ... })()" />
/// ```
///
/// ```js
/// img.setAttribute("onload", "(() => { ... })()");
/// ```
_element_attr_listeners: GlobalEventHandlersLookup = .empty,

// Blob URL registry for URL.createObjectURL/revokeObjectURL
_blob_urls: std.StringHashMapUnmanaged(*Blob) = .{},

/// `load` events that'll be fired before window's `load` event.
/// A call to `documentIsComplete` (which calls `_documentIsComplete`) resets it.
_to_load: std.ArrayList(*Element.Html) = .{},

_script_manager: ScriptManager,

// List of active MutationObservers
_mutation_observers: std.DoublyLinkedList = .{},
_mutation_delivery_scheduled: bool = false,
_mutation_delivery_depth: u32 = 0,

// List of active IntersectionObservers
_intersection_observers: std.ArrayList(*IntersectionObserver) = .{},
_intersection_check_scheduled: bool = false,
_intersection_delivery_scheduled: bool = false,

// Slots that need slotchange events to be fired
_slots_pending_slotchange: std.AutoHashMapUnmanaged(*Element.Html.Slot, void) = .{},
_slotchange_delivery_scheduled: bool = false,

/// List of active PerformanceObservers.
/// Contrary to MutationObserver and IntersectionObserver, these are regular tasks.
_performance_observers: std.ArrayList(*PerformanceObserver) = .{},
_performance_delivery_scheduled: bool = false,

// Lookup for customized built-in elements. Maps element pointer to definition.
_customized_builtin_definitions: std.AutoHashMapUnmanaged(*Element, *CustomElementDefinition) = .{},
_customized_builtin_connected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},
_customized_builtin_disconnected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},

// This is set when an element is being upgraded (constructor is called).
// The constructor can access this to get the element being upgraded.
_upgrading_element: ?*Node = null,

// List of custom elements that were created before their definition was registered
_undefined_custom_elements: std.ArrayList(*Element.Html.Custom) = .{},

// for heap allocations and managing WebAPI objects
_factory: *Factory,

_load_state: LoadState = .waiting,

_parse_state: ParseState = .pre,

_notified_network_idle: IdleNotification = .init,
_notified_network_almost_idle: IdleNotification = .init,

// A navigation event that happens from a script gets scheduled to run on the
// next tick.
_queued_navigation: ?*QueuedNavigation = null,

// The URL of the current page
url: [:0]const u8 = "about:blank",

// The base url specifies the base URL used to resolve the relative urls.
// It is set by a <base> tag.
// If null the url must be used.
base_url: ?[:0]const u8 = null,

// referer header cache.
referer_header: ?[:0]const u8 = null,

// Arbitrary buffer. Need to temporarily lowercase a value? Use this. No lifetime
// guarantee - it's valid until someone else uses it.
buf: [BUF_SIZE]u8 = undefined,

// access to the JavaScript engine
js: *JS.Context,

// An arena for the lifetime of the page.
arena: Allocator,

// An arena with a lifetime guaranteed to be for 1 invoking of a Zig function
// from JS. Best arena to use, when possible.
call_arena: Allocator,

arena_pool: *ArenaPool,
// In Debug, we use this to see if anything fails to release an arena back to
// the pool.
_arena_pool_leak_track: (if (IS_DEBUG) std.AutoHashMapUnmanaged(usize, struct {
    owner: []const u8,
    count: usize,
}) else void) = if (IS_DEBUG) .empty else {},

parent: ?*Page,
window: *Window,
document: *Document,
iframe: ?*Element.Html.IFrame = null,
frames: std.ArrayList(*Page) = .{},
frames_sorted: bool = true,

// DOM version used to invalidate cached state of "live" collections
version: usize = 0,

// This is maybe not great. It's a counter on the number of events that we're
// waiting on before triggering the "load" event. Essentially, we need all
// synchronous scripts and all iframes to be loaded. Scripts are handled by the
// ScriptManager, so all scripts just count as 1 pending load.
_pending_loads: u32,

_parent_notified: if (IS_DEBUG) bool else void = if (IS_DEBUG) false else {},

_type: enum { root, frame }, // only used for logs right now
_req_id: u32 = 0,
_navigated_options: ?NavigatedOpts = null,

pub fn init(self: *Page, id: u32, session: *Session, parent: ?*Page) !void {
    if (comptime IS_DEBUG) {
        log.debug(.page, "page.init", .{});
    }
    const browser = session.browser;
    const arena_pool = browser.arena_pool;

    const page_arena = if (parent) |p| p.arena else try arena_pool.acquire();
    errdefer if (parent == null) arena_pool.release(page_arena);

    var factory = if (parent) |p| p._factory else try Factory.init(page_arena);

    const call_arena = try arena_pool.acquire();
    errdefer arena_pool.release(call_arena);

    const document = (try factory.document(Node.Document.HTMLDocument{
        ._proto = undefined,
    })).asDocument();

    self.* = .{
        .id = id,
        .js = undefined,
        .parent = parent,
        .arena = page_arena,
        .document = document,
        .window = undefined,
        .arena_pool = arena_pool,
        .call_arena = call_arena,
        ._session = session,
        ._factory = factory,
        ._pending_loads = 1, // always 1 for the ScriptManager
        ._type = if (parent == null) .root else .frame,
        ._script_manager = undefined,
        ._event_manager = EventManager.init(page_arena, self),
    };

    var screen: *Screen = undefined;
    var visual_viewport: *VisualViewport = undefined;
    if (parent) |p| {
        screen = p.window._screen;
        visual_viewport = p.window._visual_viewport;
    } else {
        screen = try factory.eventTarget(Screen{
            ._proto = undefined,
            ._orientation = null,
        });
        visual_viewport = try factory.eventTarget(VisualViewport{
            ._proto = undefined,
        });
    }

    self.window = try factory.eventTarget(Window{
        ._page = self,
        ._proto = undefined,
        ._document = self.document,
        ._location = &default_location,
        ._performance = Performance.init(),
        ._screen = screen,
        ._visual_viewport = visual_viewport,
    });

    self._script_manager = ScriptManager.init(browser.allocator, browser.http_client, self);
    errdefer self._script_manager.deinit();

    self.js = try browser.env.createContext(self);
    errdefer self.js.deinit();

    document._page = self;

    if (comptime builtin.is_test == false) {
        // HTML test runner manually calls these as necessary
        try self.js.scheduler.add(session.browser, struct {
            fn runIdleTasks(ctx: *anyopaque) !?u32 {
                const b: *@import("Browser.zig") = @ptrCast(@alignCast(ctx));
                b.runIdleTasks();
                return 200;
            }
        }.runIdleTasks, 200, .{ .name = "page.runIdleTasks", .low_priority = true });
    }
}

pub fn deinit(self: *Page) void {
    for (self.frames.items) |frame| {
        frame.deinit();
    }

    if (comptime IS_DEBUG) {
        log.debug(.page, "page.deinit", .{ .url = self.url, .type = self._type });

        // Uncomment if you want slab statistics to print.
        // const stats = self._factory._slab.getStats(self.arena) catch unreachable;
        // var buffer: [256]u8 = undefined;
        // var stream = std.fs.File.stderr().writer(&buffer).interface;
        // stats.print(&stream) catch unreachable;
    }

    if (self._queued_navigation) |qn| {
        self.arena_pool.release(qn.arena);
    }

    const session = self._session;
    session.browser.env.destroyContext(self.js);

    self._script_manager.shutdown = true;
    session.browser.http_client.abort();
    self._script_manager.deinit();

    if (comptime IS_DEBUG) {
        var it = self._arena_pool_leak_track.valueIterator();
        while (it.next()) |value_ptr| {
            if (value_ptr.count > 0) {
                log.err(.bug, "ArenaPool Leak", .{ .owner = value_ptr.owner, .type = self._type, .url = self.url });
            }
        }
    }

    self.arena_pool.release(self.call_arena);

    if (self.parent == null) {
        self.arena_pool.release(self.arena);
    }
}

pub fn base(self: *const Page) [:0]const u8 {
    return self.base_url orelse self.url;
}

pub fn getTitle(self: *Page) !?[]const u8 {
    if (self.window._document.is(Document.HTMLDocument)) |html_doc| {
        return try html_doc.getTitle(self);
    }
    return null;
}

pub fn getOrigin(self: *Page, allocator: Allocator) !?[]const u8 {
    return try URL.getOrigin(allocator, self.url);
}

// Add comon headers for a request:
// * cookies
// * referer
pub fn headersForRequest(self: *Page, temp: Allocator, url: [:0]const u8, headers: *Http.Headers) !void {
    try self.requestCookie(.{}).headersForRequest(temp, url, headers);

    // Build the referer
    const referer = blk: {
        if (self.referer_header == null) {
            // build the cache
            if (std.mem.startsWith(u8, self.url, "http")) {
                self.referer_header = try std.mem.concatWithSentinel(self.arena, u8, &.{ "Referer: ", self.url }, 0);
            } else {
                self.referer_header = "";
            }
        }

        break :blk self.referer_header.?;
    };

    // If the referer is empty, ignore the header.
    if (referer.len > 0) {
        try headers.add(referer);
    }
}

const GetArenaOpts = struct {
    debug: []const u8,
};
pub fn getArena(self: *Page, comptime opts: GetArenaOpts) !Allocator {
    const allocator = try self.arena_pool.acquire();
    if (comptime IS_DEBUG) {
        const gop = try self._arena_pool_leak_track.getOrPut(self.arena, @intFromPtr(allocator.ptr));
        if (gop.found_existing) {
            std.debug.assert(gop.value_ptr.count == 0);
        }
        gop.value_ptr.* = .{ .owner = opts.debug, .count = 1 };
    }
    return allocator;
}

pub fn releaseArena(self: *Page, allocator: Allocator) void {
    if (comptime IS_DEBUG) {
        const found = self._arena_pool_leak_track.getPtr(@intFromPtr(allocator.ptr)).?;
        if (found.count != 1) {
            log.err(.bug, "ArenaPool Double Free", .{ .owner = found.owner, .count = found.count, .type = self._type, .url = self.url });
            return;
        }
        found.count = 0;
    }
    return self.arena_pool.release(allocator);
}

pub fn isSameOrigin(self: *const Page, url: [:0]const u8) !bool {
    const current_origin = (try URL.getOrigin(self.call_arena, self.url)) orelse return false;
    return std.mem.startsWith(u8, url, current_origin);
}

pub fn navigate(self: *Page, request_url: [:0]const u8, opts: NavigateOpts) !void {
    lp.assert(self._load_state == .waiting, "page.renavigate", .{});
    const session = self._session;
    self._load_state = .parsing;

    const req_id = self._session.browser.http_client.nextReqId();
    log.info(.page, "navigate", .{
        .url = request_url,
        .method = opts.method,
        .reason = opts.reason,
        .body = opts.body != null,
        .req_id = req_id,
        .type = self._type,
    });

    // if the url is about:blank, we load an empty HTML document in the
    // page and dispatch the events.
    if (std.mem.eql(u8, "about:blank", request_url)) {
        // Assume we parsed the document.
        // It's important to force a reset during the following navigation.
        self._parse_state = .complete;

        // We do not processHTMLDoc here as we know we don't have any scripts
        // This assumption may be false when CDP Page.addScriptToEvaluateOnNewDocument is implemented
        self.documentIsComplete();

        session.notification.dispatch(.page_navigate, &.{
            .page_id = self.id,
            .req_id = req_id,
            .opts = opts,
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        // Record telemetry for navigation
        session.browser.app.telemetry.record(.{
            .navigate = .{
                .tls = false, // about:blank is not TLS
                .proxy = session.browser.app.config.httpProxy() != null,
            },
        });

        session.notification.dispatch(.page_navigated, &.{
            .page_id = self.id,
            .req_id = req_id,
            .opts = .{
                .cdp_id = opts.cdp_id,
                .reason = opts.reason,
                .method = opts.method,
            },
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        // force next request id manually b/c we won't create a real req.
        _ = session.browser.http_client.incrReqId();
        return;
    }

    var http_client = session.browser.http_client;

    self.url = try self.arena.dupeZ(u8, request_url);

    self._req_id = req_id;
    self._navigated_options = .{
        .cdp_id = opts.cdp_id,
        .reason = opts.reason,
        .method = opts.method,
    };

    var headers = try http_client.newHeaders();
    if (opts.header) |hdr| {
        try headers.add(hdr);
    }
    try self.requestCookie(.{ .is_navigation = true }).headersForRequest(self.arena, self.url, &headers);

    // We dispatch page_navigate event before sending the request.
    // It ensures the event page_navigated is not dispatched before this one.
    session.notification.dispatch(.page_navigate, &.{
        .page_id = self.id,
        .req_id = req_id,
        .opts = opts,
        .url = self.url,
        .timestamp = timestamp(.monotonic),
    });

    // Record telemetry for navigation
    session.browser.app.telemetry.record(.{ .navigate = .{
        .tls = std.ascii.startsWithIgnoreCase(self.url, "https://"),
        .proxy = session.browser.app.config.httpProxy() != null,
    } });

    session.navigation._current_navigation_kind = opts.kind;

    http_client.request(.{
        .ctx = self,
        .url = self.url,
        .page_id = self.id,
        .method = opts.method,
        .headers = headers,
        .body = opts.body,
        .cookie_jar = &session.cookie_jar,
        .resource_type = .document,
        .notification = self._session.notification,
        .header_callback = pageHeaderDoneCallback,
        .data_callback = pageDataCallback,
        .done_callback = pageDoneCallback,
        .error_callback = pageErrorCallback,
    }) catch |err| {
        log.err(.page, "navigate request", .{ .url = self.url, .err = err, .type = self._type });
        return err;
    };
}

// We cannot navigate immediately as navigating will delete the DOM tree,
// which holds this event's node.
// As such we schedule the function to be called as soon as possible.
pub fn scheduleNavigation(self: *Page, request_url: []const u8, opts: NavigateOpts, priority: NavigationPriority) !void {
    if (self.canScheduleNavigation(priority) == false) {
        return;
    }
    const arena = try self.arena_pool.acquire();
    errdefer self.arena_pool.release(arena);
    return self.scheduleNavigationWithArena(arena, request_url, opts, priority);
}

fn scheduleNavigationWithArena(self: *Page, arena: Allocator, request_url: []const u8, opts: NavigateOpts, priority: NavigationPriority) !void {
    const resolved_url = try URL.resolve(
        arena,
        self.base(),
        request_url,
        .{ .always_dupe = true, .encode = true },
    );

    const session = self._session;
    if (!opts.force and URL.eqlDocument(self.url, resolved_url)) {
        self.arena_pool.release(arena);

        self.url = try self.arena.dupeZ(u8, resolved_url);
        self.window._location = try Location.init(self.url, self);
        self.document._location = self.window._location;
        return session.navigation.updateEntries(self.url, opts.kind, self, true);
    }

    log.info(.browser, "schedule navigation", .{
        .url = resolved_url,
        .reason = opts.reason,
        .target = resolved_url,
        .type = self._type,
    });

    session.browser.http_client.abort();

    const qn = try arena.create(QueuedNavigation);
    qn.* = .{
        .opts = opts,
        .arena = arena,
        .url = resolved_url,
        .priority = priority,
    };

    if (self._queued_navigation) |existing| {
        self.arena_pool.release(existing.arena);
    }
    self._queued_navigation = qn;
}

// A script can have multiple competing navigation events, say it starts off
// by doing top.location = 'x' and then does a form submission.
// You might think that we just stop at the first one, but that doesn't seem
// to be what browsers do, and it isn't particularly well supported by v8 (i.e.
// halting execution mid-script).
// From what I can tell, there are 3 "levels" of priority, in order:
// 1 - form submission
// 2 - JavaScript apis (e.g. top.location)
// 3 - anchor clicks
// Within, each category, it's last-one-wins.
fn canScheduleNavigation(self: *Page, priority: NavigationPriority) bool {
    const existing = self._queued_navigation orelse return true;

    if (existing.priority == priority) {
        // same reason, than this latest one wins
        return true;
    }

    return switch (existing.priority) {
        .anchor => true, // everything is higher priority than an anchor
        .form => false, // nothing is higher priority than a form
        .script => priority == .form, // a form is higher priority than a script
    };
}

pub fn documentIsLoaded(self: *Page) void {
    if (self._load_state != .parsing) {
        // Ideally, documentIsLoaded would only be called once, but if a
        // script is dynamically added from an async script after
        // documentIsLoaded is already called, then ScriptManager will call
        // it again.
        return;
    }

    self._load_state = .load;
    self.document._ready_state = .interactive;
    self._documentIsLoaded() catch |err| {
        log.err(.page, "document is loaded", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn _documentIsLoaded(self: *Page) !void {
    const event = try Event.initTrusted(.wrap("DOMContentLoaded"), .{ .bubbles = true }, self);
    try self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    );
}

pub fn scriptsCompletedLoading(self: *Page) void {
    self.pendingLoadCompleted();
}

pub fn iframeCompletedLoading(self: *Page, iframe: *Element.Html.IFrame) void {
    blk: {
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        const event = Event.initTrusted(comptime .wrap("load"), .{}, self) catch |err| {
            log.err(.page, "iframe event init", .{ .err = err, .url = iframe._src });
            break :blk;
        };
        self._event_manager.dispatch(iframe.asNode().asEventTarget(), event) catch |err| {
            log.warn(.js, "iframe onload", .{ .err = err, .url = iframe._src });
        };
    }
    self.pendingLoadCompleted();
}

fn pendingLoadCompleted(self: *Page) void {
    const pending_loads = self._pending_loads;
    if (pending_loads == 1) {
        self._pending_loads = 0;
        self.documentIsComplete();
    } else {
        self._pending_loads = pending_loads - 1;
    }
}

pub fn documentIsComplete(self: *Page) void {
    if (self._load_state == .complete) {
        // Ideally, documentIsComplete would only be called once, but with
        // dynamic scripts, it can be hard to keep track of that. An async
        // script could be evaluated AFTER Loaded and Complete and load its
        // own non non-async script - which, upon completion, needs to check
        // whether Laoded/Complete have already been called, which is what
        // this guard is.
        return;
    }

    // documentIsComplete could be called directly, without first calling
    // documentIsLoaded, if there were _only_ async scripts
    if (self._load_state == .parsing) {
        self.documentIsLoaded();
    }

    self._load_state = .complete;
    self._documentIsComplete() catch |err| {
        log.err(.page, "document is complete", .{ .err = err, .type = self._type, .url = self.url });
    };

    if (IS_DEBUG) {
        std.debug.assert(self._navigated_options != null);
    }

    self._session.notification.dispatch(.page_navigated, &.{
        .page_id = self.id,
        .req_id = self._req_id,
        .opts = self._navigated_options.?,
        .url = self.url,
        .timestamp = timestamp(.monotonic),
    });
}

fn _documentIsComplete(self: *Page) !void {
    self.document._ready_state = .complete;

    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    {
        // Dispatch `_to_load` events before window.load.
        const has_dom_load_listener = self._event_manager.has_dom_load_listener;
        for (self._to_load.items) |html_element| {
            if (has_dom_load_listener or html_element.hasAttributeFunction(.onload, self)) {
                const event = try Event.initTrusted(comptime .wrap("load"), .{}, self);
                try self._event_manager.dispatch(html_element.asEventTarget(), event);
            }
        }
    }
    // `_to_load` can be cleaned here.
    self._to_load.clearAndFree(self.arena);

    // Dispatch window.load event.
    const event = try Event.initTrusted(comptime .wrap("load"), .{}, self);
    // This event is weird, it's dispatched directly on the window, but
    // with the document as the target.
    event._target = self.document.asEventTarget();
    try self._event_manager.dispatchWithFunction(
        self.window.asEventTarget(),
        event,
        ls.toLocal(self.window._on_load),
        .{ .inject_target = false, .context = "page load" },
    );

    const pageshow_event = (try PageTransitionEvent.initTrusted(comptime .wrap("pageshow"), .{}, self)).asEvent();
    try self._event_manager.dispatchWithFunction(
        self.window.asEventTarget(),
        pageshow_event,
        ls.toLocal(self.window._on_pageshow),
        .{ .context = "page show" },
    );

    self.notifyParentLoadComplete();
}

fn notifyParentLoadComplete(self: *Page) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self._parent_notified == false);
        self._parent_notified = true;
    }

    if (self.parent) |p| {
        p.iframeCompletedLoading(self.iframe.?);
    }
}

fn pageHeaderDoneCallback(transfer: *Http.Transfer) !bool {
    var self: *Page = @ptrCast(@alignCast(transfer.ctx));

    // would be different than self.url in the case of a redirect
    const header = &transfer.response_header.?;
    self.url = try self.arena.dupeZ(u8, std.mem.span(header.url));

    self.window._location = try Location.init(self.url, self);
    self.document._location = self.window._location;

    if (comptime IS_DEBUG) {
        log.debug(.page, "navigate header", .{
            .url = self.url,
            .status = header.status,
            .content_type = header.contentType(),
            .type = self._type,
        });
    }

    return true;
}

fn pageDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    var self: *Page = @ptrCast(@alignCast(transfer.ctx));

    if (self._parse_state == .pre) {
        // we lazily do this, because we might need the first chunk of data
        // to sniff the content type
        const mime: Mime = blk: {
            if (transfer.response_header.?.contentType()) |ct| {
                break :blk try Mime.parse(ct);
            }
            break :blk Mime.sniff(data);
        } orelse .unknown;

        if (comptime IS_DEBUG) {
            log.debug(.page, "navigate first chunk", .{ .content_type = mime.content_type, .len = data.len, .type = self._type, .url = self.url });
        }

        switch (mime.content_type) {
            .text_html => self._parse_state = .{ .html = .{} },
            .application_json, .text_javascript, .text_css, .text_plain => {
                var arr: std.ArrayList(u8) = .empty;
                try arr.appendSlice(self.arena, "<html><head><meta charset=\"utf-8\"></head><body><pre>");
                self._parse_state = .{ .text = arr };
            },
            .image_jpeg, .image_gif, .image_png, .image_webp => {
                self._parse_state = .{ .image = .empty };
            },
            else => self._parse_state = .{ .raw = .empty },
        }
    }

    switch (self._parse_state) {
        .html => |*buf| try buf.appendSlice(self.arena, data),
        .text => |*buf| {
            // we have to escape the data...
            var v = data;
            while (v.len > 0) {
                const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '<', '>' }) orelse {
                    return buf.appendSlice(self.arena, v);
                };
                try buf.appendSlice(self.arena, v[0..index]);
                switch (v[index]) {
                    '<' => try buf.appendSlice(self.arena, "&lt;"),
                    '>' => try buf.appendSlice(self.arena, "&gt;"),
                    else => unreachable,
                }
                v = v[index + 1 ..];
            }
        },
        .raw, .image => |*buf| try buf.appendSlice(self.arena, data),
        .pre => unreachable,
        .complete => unreachable,
        .err => unreachable,
        .raw_done => unreachable,
    }
}

fn pageDoneCallback(ctx: *anyopaque) !void {
    var self: *Page = @ptrCast(@alignCast(ctx));

    if (comptime IS_DEBUG) {
        log.debug(.page, "navigate done", .{ .type = self._type, .url = self.url });
    }

    //We need to handle different navigation types differently.
    try self._session.navigation.commitNavigation(self);

    defer if (comptime IS_DEBUG) {
        log.debug(.page, "page.load.complete", .{ .url = self.url, .type = self._type });
    };

    const parse_arena = try self.getArena(.{ .debug = "Page.parse" });
    defer self.releaseArena(parse_arena);

    var parser = Parser.init(parse_arena, self.document.asNode(), self);

    switch (self._parse_state) {
        .html => |buf| {
            parser.parse(buf.items);
            self._script_manager.staticScriptsDone();
            if (self._script_manager.isDone()) {
                // No scripts, or just inline scripts that were already processed
                // we need to trigger this ourselves
                self.documentIsComplete();
            }
            self._parse_state = .complete;
        },
        .text => |*buf| {
            try buf.appendSlice(self.arena, "</pre></body></html>");
            parser.parse(buf.items);
            self.documentIsComplete();
        },
        .image => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an HTML containing the image.
            const html = try std.mem.concat(parse_arena, u8, &.{
                "<html><head><meta charset=\"utf-8\"></head><body><img src=\"",
                self.url,
                "\"></body></htm>",
            });
            parser.parse(html);
            self.documentIsComplete();
        },
        .raw => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></htm>");
            self.documentIsComplete();
        },
        .pre => {
            // Received a response without a body like: https://httpbin.io/status/200
            // We assume we have received an OK status (checked in Client.headerCallback)
            // so we load a blank document to navigate away from any prior page.
            self._parse_state = .{ .complete = {} };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></htm>");
            self.documentIsComplete();
        },
        .err => |err| {
            // Generate a pseudo HTML page indicating the failure.
            const html = try std.mem.concat(parse_arena, u8, &.{
                "<html><head><meta charset=\"utf-8\"></head><body><h1>Navigation failed</h1><p>Reason: ",
                @errorName(err),
                "</p></body></htm>",
            });

            parser.parse(html);
            self.documentIsComplete();
        },
        else => unreachable,
    }
}

fn pageErrorCallback(ctx: *anyopaque, err: anyerror) void {
    var self: *Page = @ptrCast(@alignCast(ctx));

    log.err(.page, "navigate failed", .{ .err = err, .type = self._type, .url = self.url });
    self._parse_state = .{ .err = err };

    // In case of error, we want to complete the page with a custom HTML
    // containing the error.
    pageDoneCallback(ctx) catch |e| {
        log.err(.browser, "pageErrorCallback", .{ .err = e, .type = self._type, .url = self.url });
        return;
    };
}

pub fn isGoingAway(self: *const Page) bool {
    return self._queued_navigation != null;
}

pub fn scriptAddedCallback(self: *Page, comptime from_parser: bool, script: *Element.Html.Script) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another page, don't run this script
        return;
    }

    self._script_manager.addFromElement(from_parser, script, "parsing") catch |err| {
        log.err(.page, "page.scriptAddedCallback", .{
            .err = err,
            .url = self.url,
            .src = script.asElement().getAttributeSafe(comptime .wrap("src")),
            .type = self._type,
        });
    };
}

pub fn iframeAddedCallback(self: *Page, iframe: *Element.Html.IFrame) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another page, don't load this iframe
        return;
    }
    if (iframe._executed) {
        return;
    }

    const src = iframe.asElement().getAttributeSafe(comptime .wrap("src")) orelse return;
    if (src.len == 0) {
        return;
    }

    iframe._executed = true;

    const session = self._session;
    const page_id = session.nextPageId();
    const page_frame = try self.arena.create(Page);
    try Page.init(page_frame, page_id, session, self);

    self._pending_loads += 1;
    page_frame.iframe = iframe;
    iframe._content_window = page_frame.window;

    self._session.notification.dispatch(.page_frame_created, &.{
        .page_id = page_id,
        .parent_id = self.id,
        .timestamp = timestamp(.monotonic),
    });

    // navigate will dupe the url
    const url = try URL.resolve(
        self.call_arena,
        self.base(),
        src,
        .{ .encode = true },
    );

    page_frame.navigate(url, .{ .reason = .initialFrameNavigation }) catch |err| {
        log.warn(.page, "iframe navigate failure", .{ .url = url, .err = err });
        self._pending_loads -= 1;
        iframe._content_window = null;
        page_frame.deinit();
        return error.IFrameLoadError;
    };

    // window[N] is based on document order. For now we'll just append the frame
    // at the end of our list and set frames_sorted == false. window.getFrame
    // will check this flag to decide if it needs to sort the frames or not.
    // But, we can optimize this a bit. Since we expect frames to often be
    // added in document order, we can do a quick check to see whether the list
    // is sorted or not.
    try self.frames.append(self.arena, page_frame);

    const frames_len = self.frames.items.len;
    if (frames_len == 1) {
        // this is the only frame, it must be sorted.
        return;
    }

    if (self.frames_sorted == false) {
        // the list already wasn't sorted, it still isn't
        return;
    }

    // So we added a frame into a sorted list. If this frame is sorted relative
    // to the last frame, it's still sorted
    const iframe_a = self.frames.items[frames_len - 2].iframe.?;
    const iframe_b = self.frames.items[frames_len - 1].iframe.?;

    if (iframe_a.asNode().compareDocumentPosition(iframe_b.asNode()) & 0x04 == 0) {
        // if b followed a, then & 0x04 = 0x04
        // but since we got 0, it means b does not follow a, and thus our list
        // is no longer sorted.
        self.frames_sorted = false;
    }
}

pub fn domChanged(self: *Page) void {
    self.version += 1;

    if (self._intersection_check_scheduled) {
        return;
    }

    self._intersection_check_scheduled = true;
    self.js.queueIntersectionChecks() catch |err| {
        log.err(.page, "page.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

const ElementIdMaps = struct { lookup: *std.StringHashMapUnmanaged(*Element), removed_ids: *std.StringHashMapUnmanaged(void) };

fn getElementIdMap(page: *Page, node: *Node) ElementIdMaps {
    // Walk up the tree checking for ShadowRoot and tracking the root
    var current = node;
    while (true) {
        if (current.is(ShadowRoot)) |shadow_root| {
            return .{
                .lookup = &shadow_root._elements_by_id,
                .removed_ids = &shadow_root._removed_ids,
            };
        }

        const parent = current._parent orelse {
            if (current._type == .document) {
                return .{
                    .lookup = &current._type.document._elements_by_id,
                    .removed_ids = &current._type.document._removed_ids,
                };
            }
            // Detached nodes should not have IDs registered
            if (IS_DEBUG) {
                std.debug.assert(false);
            }
            return .{
                .lookup = &page.document._elements_by_id,
                .removed_ids = &page.document._removed_ids,
            };
        };

        current = parent;
    }
}

pub fn addElementId(self: *Page, parent: *Node, element: *Element, id: []const u8) !void {
    var id_maps = self.getElementIdMap(parent);
    const gop = try id_maps.lookup.getOrPut(self.arena, id);
    if (!gop.found_existing) {
        gop.value_ptr.* = element;
        return;
    }

    const existing = gop.value_ptr.*.asNode();
    switch (element.asNode().compareDocumentPosition(existing)) {
        0x04 => gop.value_ptr.* = element,
        else => {},
    }
}

pub fn removeElementId(self: *Page, element: *Element, id: []const u8) void {
    const node = element.asNode();
    self.removeElementIdWithMaps(self.getElementIdMap(node), id);
}

pub fn removeElementIdWithMaps(self: *Page, id_maps: ElementIdMaps, id: []const u8) void {
    if (id_maps.lookup.remove(id)) {
        id_maps.removed_ids.put(self.arena, self.dupeString(id) catch return, {}) catch {};
    }
}

pub fn getElementByIdFromNode(self: *Page, node: *Node, id: []const u8) ?*Element {
    if (node.isConnected() or node.isInShadowTree()) {
        const lookup = self.getElementIdMap(node).lookup;
        return lookup.get(id);
    }
    var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(node, .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub fn registerPerformanceObserver(self: *Page, observer: *PerformanceObserver) !void {
    return self._performance_observers.append(self.arena, observer);
}

pub fn unregisterPerformanceObserver(self: *Page, observer: *PerformanceObserver) void {
    for (self._performance_observers.items, 0..) |perf_observer, i| {
        if (perf_observer == observer) {
            _ = self._performance_observers.swapRemove(i);
            return;
        }
    }
}

/// Updates performance observers with the new entry.
/// This doesn't emit callbacks but rather fills the queues of observers.
pub fn notifyPerformanceObservers(self: *Page, entry: *Performance.Entry) !void {
    for (self._performance_observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(self.arena, entry) catch |err| {
                log.err(.page, "notifyPerformanceObservers", .{ .err = err, .type = self._type, .url = self.url });
            };
        }
    }

    try self.schedulePerformanceObserverDelivery();
}

/// Schedules async delivery of performance observer records.
pub fn schedulePerformanceObserverDelivery(self: *Page) !void {
    // Already scheduled.
    if (self._performance_delivery_scheduled) {
        return;
    }
    self._performance_delivery_scheduled = true;

    return self.js.scheduler.add(
        self,
        struct {
            fn run(_page: *anyopaque) anyerror!?u32 {
                const page: *Page = @ptrCast(@alignCast(_page));
                page._performance_delivery_scheduled = false;

                // Dispatch performance observer events.
                for (page._performance_observers.items) |observer| {
                    if (observer.hasRecords()) {
                        try observer.dispatch(page);
                    }
                }

                return null;
            }
        }.run,
        0,
        .{ .low_priority = true },
    );
}

pub fn registerMutationObserver(self: *Page, observer: *MutationObserver) !void {
    self._mutation_observers.append(&observer.node);
}

pub fn unregisterMutationObserver(self: *Page, observer: *MutationObserver) void {
    self._mutation_observers.remove(&observer.node);
}

pub fn registerIntersectionObserver(self: *Page, observer: *IntersectionObserver) !void {
    try self._intersection_observers.append(self.arena, observer);
}

pub fn unregisterIntersectionObserver(self: *Page, observer: *IntersectionObserver) void {
    for (self._intersection_observers.items, 0..) |obs, i| {
        if (obs == observer) {
            _ = self._intersection_observers.swapRemove(i);
            return;
        }
    }
}

pub fn checkIntersections(self: *Page) !void {
    for (self._intersection_observers.items) |observer| {
        try observer.checkIntersections(self);
    }
}

pub fn scheduleMutationDelivery(self: *Page) !void {
    if (self._mutation_delivery_scheduled) {
        return;
    }
    self._mutation_delivery_scheduled = true;
    try self.js.queueMutationDelivery();
}

pub fn scheduleIntersectionDelivery(self: *Page) !void {
    if (self._intersection_delivery_scheduled) {
        return;
    }
    self._intersection_delivery_scheduled = true;
    try self.js.queueIntersectionDelivery();
}

pub fn scheduleSlotchangeDelivery(self: *Page) !void {
    if (self._slotchange_delivery_scheduled) {
        return;
    }
    self._slotchange_delivery_scheduled = true;
    try self.js.queueSlotchangeDelivery();
}

pub fn performScheduledIntersectionChecks(self: *Page) void {
    if (!self._intersection_check_scheduled) {
        return;
    }
    self._intersection_check_scheduled = false;
    self.checkIntersections() catch |err| {
        log.err(.page, "page.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn deliverIntersections(self: *Page) void {
    if (!self._intersection_delivery_scheduled) {
        return;
    }
    self._intersection_delivery_scheduled = false;

    // Iterate backwards to handle observers that disconnect during their callback
    var i = self._intersection_observers.items.len;
    while (i > 0) {
        i -= 1;
        const observer = self._intersection_observers.items[i];
        observer.deliverEntries(self) catch |err| {
            log.err(.page, "page.deliverIntersections", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn deliverMutations(self: *Page) void {
    if (!self._mutation_delivery_scheduled) {
        return;
    }
    self._mutation_delivery_scheduled = false;

    self._mutation_delivery_depth += 1;
    defer if (!self._mutation_delivery_scheduled) {
        // reset the depth once nothing is left to be scheduled
        self._mutation_delivery_depth = 0;
    };

    if (self._mutation_delivery_depth > 100) {
        log.err(.page, "page.MutationLimit", .{ .type = self._type, .url = self.url });
        self._mutation_delivery_depth = 0;
        return;
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.deliverRecords(self) catch |err| {
            log.err(.page, "page.deliverMutations", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn deliverSlotchangeEvents(self: *Page) void {
    if (!self._slotchange_delivery_scheduled) {
        return;
    }
    self._slotchange_delivery_scheduled = false;

    // we need to collect the pending slots, and then clear it and THEN exeute
    // the slot change. We do this in case the slotchange event itself schedules
    // more slot changes (which should only be executed on the next microtask)
    const pending = self._slots_pending_slotchange.count();

    var i: usize = 0;
    var slots = self.call_arena.alloc(*Element.Html.Slot, pending) catch |err| {
        log.err(.page, "deliverSlotchange.append", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };

    var it = self._slots_pending_slotchange.keyIterator();
    while (it.next()) |slot| {
        slots[i] = slot.*;
        i += 1;
    }
    self._slots_pending_slotchange.clearRetainingCapacity();

    for (slots) |slot| {
        const event = Event.initTrusted(comptime .wrap("slotchange"), .{ .bubbles = true }, self) catch |err| {
            log.err(.page, "deliverSlotchange.init", .{ .err = err, .type = self._type, .url = self.url });
            continue;
        };
        const target = slot.asNode().asEventTarget();
        _ = target.dispatchEvent(event, self) catch |err| {
            log.err(.page, "deliverSlotchange.dispatch", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn notifyNetworkIdle(self: *Page) void {
    lp.assert(self._notified_network_idle == .done, "Page.notifyNetworkIdle", .{});
    self._session.notification.dispatch(.page_network_idle, &.{
        .page_id = self.id,
        .req_id = self._req_id,
        .timestamp = timestamp(.monotonic),
    });
}

pub fn notifyNetworkAlmostIdle(self: *Page) void {
    lp.assert(self._notified_network_almost_idle == .done, "Page.notifyNetworkAlmostIdle", .{});
    self._session.notification.dispatch(.page_network_almost_idle, &.{
        .page_id = self.id,
        .req_id = self._req_id,
        .timestamp = timestamp(.monotonic),
    });
}

// called from the parser
pub fn appendNew(self: *Page, parent: *Node, child: Node.NodeOrText) !void {
    const node = switch (child) {
        .node => |n| n,
        .text => |txt| blk: {
            // If we're appending this adjacently to a text node, we should merge
            if (parent.lastChild()) |sibling| {
                if (sibling.is(CData.Text)) |tn| {
                    const cdata = tn._proto;
                    const existing = cdata.getData();
                    // @metric
                    // Inefficient, but we don't expect this to happen often.
                    cdata._data = try std.mem.concat(self.arena, u8, &.{ existing, txt });
                    return;
                }
            }
            break :blk try self.createTextNode(txt);
        },
    };

    lp.assert(node._parent == null, "Page.appendNew", .{});
    try self._insertNodeRelative(true, parent, node, .append, .{
        // this opts has no meaning since we're passing `true` as the first
        // parameter, which indicates this comes from the parser, and has its
        // own special processing. Still, set it to be clear.
        .child_already_connected = false,
    });
}

// called from the parser when the node and all its children have been added
pub fn nodeComplete(self: *Page, node: *Node) !void {
    Node.Build.call(node, "complete", .{ node, self }) catch |err| {
        log.err(.bug, "build.complete", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
        return err;
    };
    return self.nodeIsReady(true, node);
}

// Sets the owner document for a node. Only stores entries for nodes whose owner
// is NOT page.document to minimize memory overhead.
pub fn setNodeOwnerDocument(self: *Page, node: *Node, owner: *Document) !void {
    if (owner == self.document) {
        // No need to store if it's the main document - remove if present
        _ = self._node_owner_documents.remove(node);
    } else {
        try self._node_owner_documents.put(self.arena, node, owner);
    }
}

// Recursively sets the owner document for a node and all its descendants
pub fn adoptNodeTree(self: *Page, node: *Node, new_owner: *Document) !void {
    try self.setNodeOwnerDocument(node, new_owner);
    var it = node.childrenIterator();
    while (it.next()) |child| {
        try self.adoptNodeTree(child, new_owner);
    }
}

pub fn createElementNS(self: *Page, namespace: Element.Namespace, name: []const u8, attribute_iterator: anytype) !*Node {
    switch (namespace) {
        .html => {
            switch (name.len) {
                1 => switch (name[0]) {
                    'p' => return self.createHtmlElementT(
                        Element.Html.Paragraph,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    'a' => return self.createHtmlElementT(
                        Element.Html.Anchor,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    'b' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "b", .{}) catch unreachable, ._tag = .b },
                    ),
                    'i' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "i", .{}) catch unreachable, ._tag = .i },
                    ),
                    'q' => return self.createHtmlElementT(
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "q", .{}) catch unreachable, ._tag = .quote },
                    ),
                    's' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "s", .{}) catch unreachable, ._tag = .s },
                    ),
                    else => {},
                },
                2 => switch (@as(u16, @bitCast(name[0..2].*))) {
                    asUint("br") => return self.createHtmlElementT(
                        Element.Html.BR,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("ol") => return self.createHtmlElementT(
                        Element.Html.OL,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("ul") => return self.createHtmlElementT(
                        Element.Html.UL,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("li") => return self.createHtmlElementT(
                        Element.Html.LI,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("h1") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "h1", .{}) catch unreachable, ._tag = .h1 },
                    ),
                    asUint("h2") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "h2", .{}) catch unreachable, ._tag = .h2 },
                    ),
                    asUint("h3") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "h3", .{}) catch unreachable, ._tag = .h3 },
                    ),
                    asUint("h4") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "h4", .{}) catch unreachable, ._tag = .h4 },
                    ),
                    asUint("h5") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "h5", .{}) catch unreachable, ._tag = .h5 },
                    ),
                    asUint("h6") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "h6", .{}) catch unreachable, ._tag = .h6 },
                    ),
                    asUint("hr") => return self.createHtmlElementT(
                        Element.Html.HR,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("em") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "em", .{}) catch unreachable, ._tag = .em },
                    ),
                    asUint("dd") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "dd", .{}) catch unreachable, ._tag = .dd },
                    ),
                    asUint("dl") => return self.createHtmlElementT(
                        Element.Html.DList,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("dt") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "dt", .{}) catch unreachable, ._tag = .dt },
                    ),
                    asUint("td") => return self.createHtmlElementT(
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "td", .{}) catch unreachable, ._tag = .td },
                    ),
                    asUint("th") => return self.createHtmlElementT(
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "th", .{}) catch unreachable, ._tag = .th },
                    ),
                    asUint("tr") => return self.createHtmlElementT(
                        Element.Html.TableRow,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                3 => switch (@as(u24, @bitCast(name[0..3].*))) {
                    asUint("div") => return self.createHtmlElementT(
                        Element.Html.Div,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("img") => return self.createHtmlElementT(
                        Element.Html.Image,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("nav") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "nav", .{}) catch unreachable, ._tag = .nav },
                    ),
                    asUint("del") => return self.createHtmlElementT(
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "del", .{}) catch unreachable, ._tag = .del },
                    ),
                    asUint("ins") => return self.createHtmlElementT(
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "ins", .{}) catch unreachable, ._tag = .ins },
                    ),
                    asUint("col") => return self.createHtmlElementT(
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "col", .{}) catch unreachable, ._tag = .col },
                    ),
                    asUint("dir") => return self.createHtmlElementT(
                        Element.Html.Directory,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("map") => return self.createHtmlElementT(
                        Element.Html.Map,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("pre") => return self.createHtmlElementT(
                        Element.Html.Pre,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("sub") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "sub", .{}) catch unreachable, ._tag = .sub },
                    ),
                    asUint("sup") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "sup", .{}) catch unreachable, ._tag = .sup },
                    ),
                    asUint("dfn") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "dfn", .{}) catch unreachable, ._tag = .dfn },
                    ),
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(name[0..4].*))) {
                    asUint("span") => return self.createHtmlElementT(
                        Element.Html.Span,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("meta") => return self.createHtmlElementT(
                        Element.Html.Meta,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("link") => return self.createHtmlElementT(
                        Element.Html.Link,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("slot") => return self.createHtmlElementT(
                        Element.Html.Slot,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("html") => return self.createHtmlElementT(
                        Element.Html.Html,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("head") => return self.createHtmlElementT(
                        Element.Html.Head,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("body") => return self.createHtmlElementT(
                        Element.Html.Body,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("form") => return self.createHtmlElementT(
                        Element.Html.Form,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("main") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "main", .{}) catch unreachable, ._tag = .main },
                    ),
                    asUint("data") => return self.createHtmlElementT(
                        Element.Html.Data,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("base") => {
                        const n = try self.createHtmlElementT(
                            Element.Html.Base,
                            namespace,
                            attribute_iterator,
                            .{ ._proto = undefined },
                        );

                        // If page's base url is not already set, fill it with the base
                        // tag.
                        if (self.base_url == null) {
                            if (n.as(Element).getAttributeSafe(comptime .wrap("href"))) |href| {
                                self.base_url = try URL.resolve(self.arena, self.url, href, .{});
                            }
                        }

                        return n;
                    },
                    asUint("menu") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "menu", .{}) catch unreachable, ._tag = .menu },
                    ),
                    asUint("area") => return self.createHtmlElementT(
                        Element.Html.Area,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("font") => return self.createHtmlElementT(
                        Element.Html.Font,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("code") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "code", .{}) catch unreachable, ._tag = .code },
                    ),
                    asUint("time") => return self.createHtmlElementT(
                        Element.Html.Time,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(name[0..5].*))) {
                    asUint("input") => return self.createHtmlElementT(
                        Element.Html.Input,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("style") => return self.createHtmlElementT(
                        Element.Html.Style,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("title") => return self.createHtmlElementT(
                        Element.Html.Title,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("embed") => return self.createHtmlElementT(
                        Element.Html.Embed,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("audio") => return self.createHtmlMediaElementT(
                        Element.Html.Media.Audio,
                        namespace,
                        attribute_iterator,
                    ),
                    asUint("video") => return self.createHtmlMediaElementT(
                        Element.Html.Media.Video,
                        namespace,
                        attribute_iterator,
                    ),
                    asUint("aside") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "aside", .{}) catch unreachable, ._tag = .aside },
                    ),
                    asUint("label") => return self.createHtmlElementT(
                        Element.Html.Label,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("meter") => return self.createHtmlElementT(
                        Element.Html.Meter,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("param") => return self.createHtmlElementT(
                        Element.Html.Param,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("table") => return self.createHtmlElementT(
                        Element.Html.Table,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("thead") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "thead", .{}) catch unreachable, ._tag = .thead },
                    ),
                    asUint("tbody") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "tbody", .{}) catch unreachable, ._tag = .tbody },
                    ),
                    asUint("tfoot") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "tfoot", .{}) catch unreachable, ._tag = .tfoot },
                    ),
                    asUint("track") => return self.createHtmlElementT(
                        Element.Html.Track,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(name[0..6].*))) {
                    asUint("script") => return self.createHtmlElementT(
                        Element.Html.Script,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("button") => return self.createHtmlElementT(
                        Element.Html.Button,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("canvas") => return self.createHtmlElementT(
                        Element.Html.Canvas,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("dialog") => return self.createHtmlElementT(
                        Element.Html.Dialog,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("legend") => return self.createHtmlElementT(
                        Element.Html.Legend,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("object") => return self.createHtmlElementT(
                        Element.Html.Object,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("output") => return self.createHtmlElementT(
                        Element.Html.Output,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("source") => return self.createHtmlElementT(
                        Element.Html.Source,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("strong") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "strong", .{}) catch unreachable, ._tag = .strong },
                    ),
                    asUint("header") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "header", .{}) catch unreachable, ._tag = .header },
                    ),
                    asUint("footer") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "footer", .{}) catch unreachable, ._tag = .footer },
                    ),
                    asUint("select") => return self.createHtmlElementT(
                        Element.Html.Select,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("option") => return self.createHtmlElementT(
                        Element.Html.Option,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("iframe") => return self.createHtmlElementT(
                        Element.Html.IFrame,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("figure") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "figure", .{}) catch unreachable, ._tag = .figure },
                    ),
                    asUint("hgroup") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "hgroup", .{}) catch unreachable, ._tag = .hgroup },
                    ),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(name[0..7].*))) {
                    asUint("section") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "section", .{}) catch unreachable, ._tag = .section },
                    ),
                    asUint("article") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "article", .{}) catch unreachable, ._tag = .article },
                    ),
                    asUint("details") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "details", .{}) catch unreachable, ._tag = .details },
                    ),
                    asUint("summary") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "summary", .{}) catch unreachable, ._tag = .summary },
                    ),
                    asUint("caption") => return self.createHtmlElementT(
                        Element.Html.TableCaption,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("marquee") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "marquee", .{}) catch unreachable, ._tag = .marquee },
                    ),
                    asUint("address") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "address", .{}) catch unreachable, ._tag = .address },
                    ),
                    asUint("picture") => return self.createHtmlElementT(
                        Element.Html.Picture,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(name[0..8].*))) {
                    asUint("textarea") => return self.createHtmlElementT(
                        Element.Html.TextArea,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("template") => return self.createHtmlElementT(
                        Element.Html.Template,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._content = undefined },
                    ),
                    asUint("colgroup") => return self.createHtmlElementT(
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "colgroup", .{}) catch unreachable, ._tag = .colgroup },
                    ),
                    asUint("fieldset") => return self.createHtmlElementT(
                        Element.Html.FieldSet,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("optgroup") => return self.createHtmlElementT(
                        Element.Html.OptGroup,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("progress") => return self.createHtmlElementT(
                        Element.Html.Progress,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("datalist") => return self.createHtmlElementT(
                        Element.Html.DataList,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("noscript") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "noscript", .{}) catch unreachable, ._tag = .noscript },
                    ),
                    else => {},
                },
                10 => switch (@as(u80, @bitCast(name[0..10].*))) {
                    asUint("blockquote") => return self.createHtmlElementT(
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "blockquote", .{}) catch unreachable, ._tag = .blockquote },
                    ),
                    else => {},
                },
                else => {},
            }
            const tag_name = try String.init(self.arena, name, .{});

            // Check if this is a custom element (must have hyphen for HTML namespace)
            const has_hyphen = std.mem.indexOfScalar(u8, name, '-') != null;
            if (has_hyphen and namespace == .html) {
                const definition = self.window._custom_elements._definitions.get(name);
                const node = try self.createHtmlElementT(Element.Html.Custom, namespace, attribute_iterator, .{
                    ._proto = undefined,
                    ._tag_name = tag_name,
                    ._definition = definition,
                });

                const def = definition orelse {
                    const element = node.as(Element);
                    const custom = element.is(Element.Html.Custom).?;
                    try self._undefined_custom_elements.append(self.arena, custom);
                    return node;
                };

                // Save and restore upgrading element to allow nested createElement calls
                const prev_upgrading = self._upgrading_element;
                self._upgrading_element = node;
                defer self._upgrading_element = prev_upgrading;

                var ls: JS.Local.Scope = undefined;
                self.js.localScope(&ls);
                defer ls.deinit();

                var caught: JS.TryCatch.Caught = undefined;
                _ = ls.toLocal(def.constructor).newInstance(&caught) catch |err| {
                    log.warn(.js, "custom element constructor", .{ .name = name, .err = err, .caught = caught, .type = self._type, .url = self.url });
                    return node;
                };

                // After constructor runs, invoke attributeChangedCallback for initial attributes
                const element = node.as(Element);
                if (element._attributes) |attributes| {
                    var it = attributes.iterator();
                    while (it.next()) |attr| {
                        Element.Html.Custom.invokeAttributeChangedCallbackOnElement(
                            element,
                            attr._name,
                            null, // old_value is null for initial attributes
                            attr._value,
                            self,
                        );
                    }
                }

                return node;
            }

            return self.createHtmlElementT(Element.Html.Unknown, namespace, attribute_iterator, .{ ._proto = undefined, ._tag_name = tag_name });
        },
        .svg => {
            const tag_name = try String.init(self.arena, name, .{});
            if (std.ascii.eqlIgnoreCase(name, "svg")) {
                return self.createSvgElementT(Element.Svg, name, attribute_iterator, .{
                    ._proto = undefined,
                    ._type = .svg,
                    ._tag_name = tag_name,
                });
            }

            // Other SVG elements (rect, circle, text, g, etc.)
            const lower = std.ascii.lowerString(&self.buf, name);
            const tag = std.meta.stringToEnum(Element.Tag, lower) orelse .unknown;
            return self.createSvgElementT(Element.Svg.Generic, name, attribute_iterator, .{ ._proto = undefined, ._tag = tag });
        },
        else => {
            const tag_name = try String.init(self.arena, name, .{});
            return self.createHtmlElementT(Element.Html.Unknown, namespace, attribute_iterator, .{ ._proto = undefined, ._tag_name = tag_name });
        },
    }
}

fn createHtmlElementT(self: *Page, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype, html_element: E) !*Node {
    const html_element_ptr = try self._factory.htmlElement(html_element);
    const element = html_element_ptr.asElement();
    element._namespace = namespace;
    try self.populateElementAttributes(element, attribute_iterator);

    // Check for customized built-in element via "is" attribute
    try Element.Html.Custom.checkAndAttachBuiltIn(element, self);

    const node = element.asNode();
    if (@hasDecl(E, "Build") and @hasDecl(E.Build, "created")) {
        @call(.auto, @field(E.Build, "created"), .{ node, self }) catch |err| {
            log.err(.page, "build.created", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
            return err;
        };
    }
    return node;
}

fn createHtmlMediaElementT(self: *Page, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype) !*Node {
    const media_element = try self._factory.htmlMediaElement(E{ ._proto = undefined });
    const element = media_element.asElement();
    element._namespace = namespace;
    try self.populateElementAttributes(element, attribute_iterator);
    return element.asNode();
}

fn createSvgElementT(self: *Page, comptime E: type, tag_name: []const u8, attribute_iterator: anytype, svg_element: E) !*Node {
    const svg_element_ptr = try self._factory.svgElement(tag_name, svg_element);
    var element = svg_element_ptr.asElement();
    element._namespace = .svg;
    try self.populateElementAttributes(element, attribute_iterator);
    return element.asNode();
}

fn populateElementAttributes(self: *Page, element: *Element, list: anytype) !void {
    if (@TypeOf(list) == ?*Element.Attribute.List) {
        // from cloneNode

        var existing = list orelse return;

        var attributes = try self.arena.create(Element.Attribute.List);
        attributes.* = .{
            .normalize = existing.normalize,
        };

        var it = existing.iterator();
        while (it.next()) |attr| {
            try attributes.putNew(attr._name.str(), attr._value.str(), self);
        }
        element._attributes = attributes;
        return;
    }

    // from the parser
    if (@TypeOf(list) == @TypeOf(null) or list.count() == 0) {
        return;
    }
    var attributes = try element.createAttributeList(self);
    while (list.next()) |attr| {
        try attributes.putNew(attr.name.local.slice(), attr.value.slice(), self);
    }
}

pub fn createTextNode(self: *Page, text: []const u8) !*Node {
    // might seem unlikely that we get an intern hit, but we'll get some nodes
    // with just '\n'
    const owned_text = try self.dupeString(text);
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .text = .{
            ._proto = undefined,
        } },
        ._data = owned_text,
    });
    cd._type.text._proto = cd;
    return cd.asNode();
}

pub fn createComment(self: *Page, text: []const u8) !*Node {
    const owned_text = try self.dupeString(text);
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .comment = .{
            ._proto = undefined,
        } },
        ._data = owned_text,
    });
    cd._type.comment._proto = cd;
    return cd.asNode();
}

pub fn createCDATASection(self: *Page, data: []const u8) !*Node {
    // Validate that the data doesn't contain "]]>"
    if (std.mem.indexOf(u8, data, "]]>") != null) {
        return error.InvalidCharacterError;
    }

    const owned_data = try self.dupeString(data);

    // First allocate the Text node separately
    const text_node = try self._factory.create(CData.Text{
        ._proto = undefined,
    });

    // Then create the CData with cdata_section variant
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .cdata_section = .{
            ._proto = text_node,
        } },
        ._data = owned_data,
    });

    // Set up the back pointer from Text to CData
    text_node._proto = cd;

    return cd.asNode();
}

pub fn createProcessingInstruction(self: *Page, target: []const u8, data: []const u8) !*Node {
    // Validate neither target nor data contain "?>"
    if (std.mem.indexOf(u8, target, "?>") != null) {
        return error.InvalidCharacterError;
    }
    if (std.mem.indexOf(u8, data, "?>") != null) {
        return error.InvalidCharacterError;
    }

    // Validate target follows XML Name production
    try validateXmlName(target);

    const owned_target = try self.dupeString(target);
    const owned_data = try self.dupeString(data);

    const pi = try self._factory.create(CData.ProcessingInstruction{
        ._proto = undefined,
        ._target = owned_target,
    });

    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .processing_instruction = pi },
        ._data = owned_data,
    });

    // Set up the back pointer from ProcessingInstruction to CData
    pi._proto = cd;

    return cd.asNode();
}

/// Validate a string against the XML Name production.
/// https://www.w3.org/TR/xml/#NT-Name
fn validateXmlName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidCharacterError;

    var i: usize = 0;

    // First character must be a NameStartChar.
    const first_len = std.unicode.utf8ByteSequenceLength(name[0]) catch
        return error.InvalidCharacterError;
    if (first_len > name.len) return error.InvalidCharacterError;
    const first_cp = std.unicode.utf8Decode(name[0..][0..first_len]) catch
        return error.InvalidCharacterError;
    if (!isXmlNameStartChar(first_cp)) return error.InvalidCharacterError;
    i = first_len;

    // Subsequent characters must be NameChars.
    while (i < name.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(name[i]) catch
            return error.InvalidCharacterError;
        if (i + cp_len > name.len) return error.InvalidCharacterError;
        const cp = std.unicode.utf8Decode(name[i..][0..cp_len]) catch
            return error.InvalidCharacterError;
        if (!isXmlNameChar(cp)) return error.InvalidCharacterError;
        i += cp_len;
    }
}

fn isXmlNameStartChar(c: u21) bool {
    return c == ':' or
        (c >= 'A' and c <= 'Z') or
        c == '_' or
        (c >= 'a' and c <= 'z') or
        (c >= 0xC0 and c <= 0xD6) or
        (c >= 0xD8 and c <= 0xF6) or
        (c >= 0xF8 and c <= 0x2FF) or
        (c >= 0x370 and c <= 0x37D) or
        (c >= 0x37F and c <= 0x1FFF) or
        (c >= 0x200C and c <= 0x200D) or
        (c >= 0x2070 and c <= 0x218F) or
        (c >= 0x2C00 and c <= 0x2FEF) or
        (c >= 0x3001 and c <= 0xD7FF) or
        (c >= 0xF900 and c <= 0xFDCF) or
        (c >= 0xFDF0 and c <= 0xFFFD) or
        (c >= 0x10000 and c <= 0xEFFFF);
}

fn isXmlNameChar(c: u21) bool {
    return isXmlNameStartChar(c) or
        c == '-' or
        c == '.' or
        (c >= '0' and c <= '9') or
        c == 0xB7 or
        (c >= 0x300 and c <= 0x36F) or
        (c >= 0x203F and c <= 0x2040);
}

pub fn dupeString(self: *Page, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

const RemoveNodeOpts = struct {
    will_be_reconnected: bool,
};
pub fn removeNode(self: *Page, parent: *Node, child: *Node, opts: RemoveNodeOpts) void {
    // Capture siblings before removing
    const previous_sibling = child.previousSibling();
    const next_sibling = child.nextSibling();

    const children = parent._children.?;
    switch (children.*) {
        .one => |n| {
            lp.assert(n == child, "Page.removeNode.one", .{});
            parent._children = null;
            self._factory.destroy(children);
        },
        .list => |list| {
            list.remove(&child._child_link);

            // Should not be possible to get a child list with a single node.
            // While it doesn't cause any problems, it indicates an bug in the
            // code as these should always be represented as .{.one = node}
            const first = list.first.?;
            if (first.next == null) {
                children.* = .{ .one = Node.linkToNode(first) };
                self._factory.destroy(list);
            }
        },
    }
    // grab this before we null the parent
    const was_connected = child.isConnected();
    // Capture the ID map before disconnecting, so we can remove IDs from the correct document
    const id_maps = if (was_connected) self.getElementIdMap(child) else null;

    child._parent = null;
    child._child_link = .{};

    // Handle slot assignment removal before mutation observers
    if (child.is(Element)) |el| {
        // Check if the parent was a shadow host
        if (parent.is(Element)) |parent_el| {
            if (self._element_shadow_roots.get(parent_el)) |shadow_root| {
                // Signal slot changes for any affected slots
                const slot_name = el.getAttributeSafe(comptime .wrap("slot")) orelse "";
                var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(shadow_root.asNode(), .{});
                while (tw.next()) |slot_el| {
                    if (slot_el.is(Element.Html.Slot)) |slot| {
                        if (std.mem.eql(u8, slot.getName(), slot_name)) {
                            self.signalSlotChange(slot);
                            break;
                        }
                    }
                }
            }
        }
        // Remove from assigned slot lookup
        _ = self._element_assigned_slots.remove(el);
    }

    if (self.hasMutationObservers()) {
        const removed = [_]*Node{child};
        self.childListChange(parent, &.{}, &removed, previous_sibling, next_sibling);
    }

    if (opts.will_be_reconnected) {
        // We might be removing the node only to re-insert it. If the node will
        // remain connected, we can skip the expensive process of fully
        // disconnecting it.
        return;
    }

    if (was_connected == false) {
        // If the child wasn't connected, then there should be nothing left for
        // us to do
        return;
    }

    // The child was connected and now it no longer is. We need to "disconnect"
    // it and all of its descendants. For now "disconnect" just means updating
    // the ID map and invoking disconnectedCallback for custom elements
    var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(child, .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            self.removeElementIdWithMaps(id_maps.?, id);
        }

        Element.Html.Custom.invokeDisconnectedCallbackOnElement(el, self);
    }
}

pub fn appendNode(self: *Page, parent: *Node, child: *Node, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, .append, opts);
}

pub fn appendAllChildren(self: *Page, parent: *Node, target: *Node) !void {
    self.domChanged();
    const dest_connected = target.isConnected();

    var it = parent.childrenIterator();
    while (it.next()) |child| {
        // Check if child was connected BEFORE removing it from parent
        const child_was_connected = child.isConnected();
        self.removeNode(parent, child, .{ .will_be_reconnected = dest_connected });
        try self.appendNode(target, child, .{ .child_already_connected = child_was_connected });
    }
}

pub fn insertAllChildrenBefore(self: *Page, fragment: *Node, parent: *Node, ref_node: *Node) !void {
    self.domChanged();
    const dest_connected = parent.isConnected();

    var it = fragment.childrenIterator();
    while (it.next()) |child| {
        // Check if child was connected BEFORE removing it from fragment
        const child_was_connected = child.isConnected();
        self.removeNode(fragment, child, .{ .will_be_reconnected = dest_connected });
        try self.insertNodeRelative(
            parent,
            child,
            .{ .before = ref_node },
            .{ .child_already_connected = child_was_connected },
        );
    }
}

const InsertNodeRelative = union(enum) {
    append,
    after: *Node,
    before: *Node,
};
const InsertNodeOpts = struct {
    child_already_connected: bool = false,
    adopting_to_new_document: bool = false,
};
pub fn insertNodeRelative(self: *Page, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, relative, opts);
}
pub fn _insertNodeRelative(self: *Page, comptime from_parser: bool, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    // caller should have made sure this was the case

    lp.assert(child._parent == null, "Page.insertNodeRelative parent", .{ .url = self.url });

    const children = blk: {
        // expand parent._children so that it can take another child
        if (parent._children) |c| {
            switch (c.*) {
                .list => {},
                .one => |node| {
                    const list = try self._factory.create(std.DoublyLinkedList{});
                    list.append(&node._child_link);
                    c.* = .{ .list = list };
                },
            }
            break :blk c;
        } else {
            const Children = @import("webapi/children.zig").Children;
            const c = try self._factory.create(Children{ .one = child });
            parent._children = c;
            break :blk c;
        }
    };

    switch (relative) {
        .append => switch (children.*) {
            .one => {}, // already set in the expansion above
            .list => |list| list.append(&child._child_link),
        },
        .after => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Page.insertNodeRelative after", .{ .url = self.url });
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertAfter(&ref_node._child_link, &child._child_link);
        },
        .before => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Page.insertNodeRelative before", .{ .url = self.url });
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertBefore(&ref_node._child_link, &child._child_link);
        },
    }
    child._parent = parent;

    // Tri-state behavior for mutations:
    // 1. from_parser=true, parse_mode=document -> no mutations (initial document parse)
    // 2. from_parser=true, parse_mode=fragment -> mutations (innerHTML additions)
    // 3. from_parser=false, parse_mode=document -> mutation (js manipulation)
    // split like this because from_parser can be comptime known.
    const should_notify = if (comptime from_parser)
        self._parse_mode == .fragment
    else
        true;

    if (should_notify) {
        if (comptime from_parser == false) {
            // When the parser adds the node, nodeIsReady is only called when the
            // nodeComplete() callback is executed.
            try self.nodeIsReady(false, child);
        }

        // Notify mutation observers about childList change
        if (self.hasMutationObservers()) {
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            self.childListChange(parent, &added, &.{}, previous_sibling, next_sibling);
        }
    }

    if (comptime from_parser) {
        if (child.is(Element)) |el| {
            // Invoke connectedCallback for custom elements during parsing
            // For main document parsing, we know nodes are connected (fast path)
            // For fragment parsing (innerHTML), we need to check connectivity
            if (child.isConnected() or child.isInShadowTree()) {
                if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
                    try self.addElementId(parent, el, id);
                }
                try Element.Html.Custom.invokeConnectedCallbackOnElement(true, el, self);
            }
        }
        return;
    }

    // Update slot assignments for the inserted child if parent is a shadow host
    // This needs to happen even if the element isn't connected to the document
    if (child.is(Element)) |el| {
        self.updateElementAssignedSlot(el);
    }

    if (opts.child_already_connected and !opts.adopting_to_new_document) {
        // The child is already connected in the same document, we don't have to reconnect it
        return;
    }

    const parent_in_shadow = parent.is(ShadowRoot) != null or parent.isInShadowTree();
    const parent_is_connected = parent.isConnected();

    if (!parent_in_shadow and !parent_is_connected) {
        return;
    }

    // If we're here, it means either:
    // 1. A disconnected child became connected (parent.isConnected() == true)
    // 2. Child is being added to a shadow tree (parent_in_shadow == true)
    // In both cases, we need to update ID maps and invoke callbacks

    // Only invoke connectedCallback if the root child is transitioning from
    // disconnected to connected. When that happens, all descendants should also
    // get connectedCallback invoked (they're becoming connected as a group).
    const should_invoke_connected = parent_is_connected and !opts.child_already_connected;

    var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(child, .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            try self.addElementId(el.asNode()._parent.?, el, id);
        }

        if (should_invoke_connected) {
            try Element.Html.Custom.invokeConnectedCallbackOnElement(false, el, self);
        }
    }
}

pub fn attributeChange(self: *Page, element: *Element, name: String, value: String, old_value: ?String) void {
    _ = Element.Build.call(element, "attributeChange", .{ element, name, value, self }) catch |err| {
        log.err(.bug, "build.attributeChange", .{ .tag = element.getTag(), .name = name, .value = value, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, value, self);

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.page, "attributeChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        self.updateSlotAssignments(element);
    } else if (name.eql(comptime .wrap("name"))) {
        // Check if this is a slot element
        if (element.is(Element.Html.Slot)) |slot| {
            self.signalSlotChange(slot);
        }
    }
}

pub fn attributeRemove(self: *Page, element: *Element, name: String, old_value: String) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, null, self);

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.page, "attributeRemove.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        self.updateSlotAssignments(element);
    } else if (name.eql(comptime .wrap("name"))) {
        // Check if this is a slot element
        if (element.is(Element.Html.Slot)) |slot| {
            self.signalSlotChange(slot);
        }
    }
}

fn signalSlotChange(self: *Page, slot: *Element.Html.Slot) void {
    self._slots_pending_slotchange.put(self.arena, slot, {}) catch |err| {
        log.err(.page, "signalSlotChange.put", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };
    self.scheduleSlotchangeDelivery() catch |err| {
        log.err(.page, "signalSlotChange.schedule", .{ .err = err, .type = self._type, .url = self.url });
    };
}

fn updateSlotAssignments(self: *Page, element: *Element) void {
    // Find all slots in the shadow root that might be affected
    const parent = element.asNode()._parent orelse return;

    // Check if parent is a shadow host
    const parent_el = parent.is(Element) orelse return;
    _ = self._element_shadow_roots.get(parent_el) orelse return;

    // Signal change for the old slot (if any)
    if (self._element_assigned_slots.get(element)) |old_slot| {
        self.signalSlotChange(old_slot);
    }

    // Update the assignedSlot lookup to the new slot
    self.updateElementAssignedSlot(element);

    // Signal change for the new slot (if any)
    if (self._element_assigned_slots.get(element)) |new_slot| {
        self.signalSlotChange(new_slot);
    }
}

fn updateElementAssignedSlot(self: *Page, element: *Element) void {
    // Remove old assignment
    _ = self._element_assigned_slots.remove(element);

    // Find the new assigned slot
    const parent = element.asNode()._parent orelse return;
    const parent_el = parent.is(Element) orelse return;
    const shadow_root = self._element_shadow_roots.get(parent_el) orelse return;

    const slot_name = element.getAttributeSafe(comptime .wrap("slot")) orelse "";

    // Recursively search through the shadow root for a matching slot
    if (findMatchingSlot(shadow_root.asNode(), slot_name)) |slot| {
        self._element_assigned_slots.put(self.arena, element, slot) catch |err| {
            log.err(.page, "updateElementAssignedSlot.put", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

fn findMatchingSlot(node: *Node, slot_name: []const u8) ?*Element.Html.Slot {
    // Check if this node is a matching slot
    if (node.is(Element)) |el| {
        if (el.is(Element.Html.Slot)) |slot| {
            if (std.mem.eql(u8, slot.getName(), slot_name)) {
                return slot;
            }
        }
    }

    // Search children
    var it = node.childrenIterator();
    while (it.next()) |child| {
        if (findMatchingSlot(child, slot_name)) |slot| {
            return slot;
        }
    }

    return null;
}

pub fn hasMutationObservers(self: *const Page) bool {
    return self._mutation_observers.first != null;
}

pub fn getCustomizedBuiltInDefinition(self: *Page, element: *Element) ?*CustomElementDefinition {
    return self._customized_builtin_definitions.get(element);
}

pub fn setCustomizedBuiltInDefinition(self: *Page, element: *Element, definition: *CustomElementDefinition) !void {
    try self._customized_builtin_definitions.put(self.arena, element, definition);
}

pub fn characterDataChange(
    self: *Page,
    target: *Node,
    old_value: []const u8,
) void {
    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyCharacterDataChange(target, old_value, self) catch |err| {
            log.err(.page, "cdataChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn childListChange(
    self: *Page,
    target: *Node,
    added_nodes: []const *Node,
    removed_nodes: []const *Node,
    previous_sibling: ?*Node,
    next_sibling: ?*Node,
) void {
    // Filter out HTML wrapper element during fragment parsing (html5ever quirk)
    if (self._parse_mode == .fragment and added_nodes.len == 1) {
        if (added_nodes[0].is(Element.Html.Html) != null) {
            // This is the temporary HTML wrapper, added by html5ever
            // that will be unwrapped, see:
            // https://github.com/servo/html5ever/issues/583
            return;
        }
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyChildListChange(target, added_nodes, removed_nodes, previous_sibling, next_sibling, self) catch |err| {
            log.err(.page, "childListChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

// TODO: optimize and cleanup, this is called a lot (e.g., innerHTML = '')
pub fn parseHtmlAsChildren(self: *Page, node: *Node, html: []const u8) !void {
    const previous_parse_mode = self._parse_mode;
    self._parse_mode = .fragment;
    defer self._parse_mode = previous_parse_mode;

    var parser = Parser.init(self.call_arena, node, self);
    parser.parseFragment(html);

    // https://github.com/servo/html5ever/issues/583
    const children = node._children orelse return;
    const first = children.one;
    lp.assert(first.is(Element.Html.Html) != null, "Page.parseHtmlAsChildren root", .{ .type = first._type });
    node._children = first._children;

    if (self.hasMutationObservers()) {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
            // Notify mutation observers for each unwrapped child
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            self.childListChange(node, &added, &.{}, previous_sibling, next_sibling);
        }
    } else {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
        }
    }
}

fn nodeIsReady(self: *Page, comptime from_parser: bool, node: *Node) !void {
    if ((comptime from_parser) and self._parse_mode == .fragment) {
        // we don't execute scripts added via innerHTML = '<script...';
        return;
    }
    if (node.is(Element.Html.Script)) |script| {
        if ((comptime from_parser == false) and script._src.len == 0) {
            // script was added via JavaScript, but without a src, don't try
            // to execute it (we'll execute it if/when the src is set)
            return;
        }

        self.scriptAddedCallback(from_parser, script) catch |err| {
            log.err(.page, "page.nodeIsReady", .{ .err = err, .element = "script", .type = self._type, .url = self.url });
            return err;
        };
    } else if (node.is(Element.Html.IFrame)) |iframe| {
        if ((comptime from_parser == false) and iframe._src.len == 0) {
            // iframe was added via JavaScript, but without a src
            return;
        }

        self.iframeAddedCallback(iframe) catch |err| {
            log.err(.page, "page.nodeIsReady", .{ .err = err, .element = "iframe", .type = self._type, .url = self.url });
            return err;
        };
    }
}

const ParseState = union(enum) {
    pre,
    complete,
    err: anyerror,
    html: std.ArrayList(u8),
    text: std.ArrayList(u8),
    image: std.ArrayList(u8),
    raw: std.ArrayList(u8),
    raw_done: []const u8,
};

const LoadState = enum {
    // waiting for the main HTML
    waiting,

    // the main HTML is being parsed (or downloaded)
    parsing,

    // the main HTML has been parsed and the JavaScript (including deferred
    // scripts) have been loaded. Corresponds to the DOMContentLoaded event
    load,

    // the page has been loaded and all async scripts (if any) are done
    // Corresponds to the load event
    complete,
};

const IdleNotification = union(enum) {
    // hasn't started yet.
    init,

    // timestamp where the state was first triggered. If the state stays
    // true (e.g. 0 nework activity for NetworkIdle, or <= 2 for NetworkAlmostIdle)
    // for 500ms, it'll send the notification and transition to .done. If
    // the state doesn't stay true, it'll revert to .init.
    triggered: u64,

    // notification sent - should never be reset
    done,

    // Returns `true` if we should send a notification. Only returns true if it
    // was previously triggered 500+ milliseconds ago.
    // active == true when the condition for the notification is true
    // active == false when the condition for the notification is false
    pub fn check(self: *IdleNotification, active: bool) bool {
        if (active) {
            switch (self.*) {
                .done => {
                    // Notification was already sent.
                },
                .init => {
                    // This is the first time the condition was triggered (or
                    // the first time after being un-triggered). Record the time
                    // so that if the condition holds for long enough, we can
                    // send a notification.
                    self.* = .{ .triggered = milliTimestamp(.monotonic) };
                },
                .triggered => |ms| {
                    // The condition was already triggered and was triggered
                    // again. When this condition holds for 500+ms, we'll send
                    // a notification.
                    if (milliTimestamp(.monotonic) - ms >= 500) {
                        // This is the only place in this function where we can
                        // return true. The only place where we can tell our caller
                        // "send the notification!".
                        self.* = .done;
                        return true;
                    }
                    // the state hasn't held for 500ms.
                },
            }
        } else {
            switch (self.*) {
                .done => {
                    // The condition became false, but we already sent the notification
                    // There's nothing we can do, it stays .done. We never re-send
                    // a notification or "undo" a sent notification (not that we can).
                },
                .init => {
                    // The condition remains false
                },
                .triggered => {
                    // The condition _had_ been true, and we were waiting (500ms)
                    // for it to hold, but it hasn't. So we go back to waiting.
                    self.* = .init;
                },
            }
        }

        // See above for the only case where we ever return true. All other
        // paths go here. This means "don't send the notification". Maybe
        // because it's already been sent, maybe because active is false, or
        // maybe because the condition hasn't held long enough.
        return false;
    }
};

pub const NavigateReason = enum {
    anchor,
    address_bar,
    form,
    script,
    history,
    navigation,
    initialFrameNavigation,
};

pub const NavigateOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: Http.Method = .GET,
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
    force: bool = false,
    kind: NavigationKind = .{ .push = null },
};

pub const NavigatedOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: Http.Method = .GET,
};

const NavigationPriority = enum {
    form,
    script,
    anchor,
};

pub const QueuedNavigation = struct {
    arena: Allocator,
    url: [:0]const u8,
    opts: NavigateOpts,
    priority: NavigationPriority,
};

pub fn triggerMouseClick(self: *Page, x: f64, y: f64) !void {
    const target = (try self.window._document.elementFromPoint(x, y, self)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.page, "page mouse click", .{
            .url = self.url,
            .node = target,
            .x = x,
            .y = y,
            .type = self._type,
        });
    }
    const event = (try @import("webapi/event/MouseEvent.zig").init("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, self)).asEvent();
    try self._event_manager.dispatch(target.asEventTarget(), event);
}

// callback when the "click" event reaches the pages.
pub fn handleClick(self: *Page, target: *Node) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;
    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => |anchor| {
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
            if (href.len == 0) {
                return;
            }

            if (std.mem.startsWith(u8, href, "javascript:")) {
                return;
            }

            // Check target attribute - don't navigate if opening in new window/tab
            const target_val = anchor.getTarget();
            if (target_val.len > 0 and !std.mem.eql(u8, target_val, "_self")) {
                log.warn(.not_implemented, "a.target", .{ .type = self._type, .url = self.url });
                return;
            }

            if (try element.hasAttribute(comptime .wrap("download"), self)) {
                log.warn(.browser, "a.download", .{ .type = self._type, .url = self.url });
                return;
            }

            try element.focus(self);
            try self.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .anchor);
        },
        .input => |input| {
            try element.focus(self);
            if (input._input_type == .submit) {
                return self.submitForm(element, input.getForm(self), .{});
            }
        },
        .button => |button| {
            try element.focus(self);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return self.submitForm(element, button.getForm(self), .{});
            }
        },
        .select, .textarea => try element.focus(self),
        else => {},
    }
}

pub fn triggerKeyboard(self: *Page, keyboard_event: *KeyboardEvent) !void {
    const event = keyboard_event.asEvent();
    const element = self.window._document._active_element orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.page, "page keydown", .{
            .url = self.url,
            .node = element,
            .key = keyboard_event._key,
            .type = self._type,
        });
    }
    try self._event_manager.dispatch(element.asEventTarget(), event);
}

pub fn handleKeydown(self: *Page, target: *Node, event: *Event) !void {
    const keyboard_event = event.as(KeyboardEvent);
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            return self.submitForm(input.asElement(), input.getForm(self), .{});
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        // Handle printable characters
        if (key.isPrintable()) {
            try input.innerInsert(key.asString(), self);
        }
        return;
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        // zig fmt: off
        const append =
            if (key == .Enter) "\n"
            else if (key.isPrintable()) key.asString()
            else return
        ;
        // zig fmt: on
        return textarea.innerInsert(append, self);
    }
}

const SubmitFormOpts = struct {
    fire_event: bool = true,
};
pub fn submitForm(self: *Page, submitter_: ?*Element, form_: ?*Element.Html.Form, submit_opts: SubmitFormOpts) !void {
    const form = form_ orelse return;

    if (submitter_) |submitter| {
        if (submitter.getAttributeSafe(comptime .wrap("disabled")) != null) {
            return;
        }
    }

    if (self.canScheduleNavigation(.form) == false) {
        return;
    }

    const form_element = form.asElement();

    if (submit_opts.fire_event) {
        const onsubmit_handler = try form.asHtmlElement().getOnSubmit(self);
        const submit_event = try Event.initTrusted(comptime .wrap("submit"), .{ .bubbles = true, .cancelable = true }, self);

        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        try self._event_manager.dispatchWithFunction(
            form_element.asEventTarget(),
            submit_event,
            ls.toLocal(onsubmit_handler),
            .{ .context = "form submit" },
        );

        // If the submit event was prevented, don't submit the form
        if (submit_event._prevent_default) {
            return;
        }
    }

    const FormData = @import("webapi/net/FormData.zig");
    // The submitter can be an input box (if enter was entered on the box)
    // I don't think this is technically correct, but FormData handles it ok
    const form_data = try FormData.init(form, submitter_, self);

    const arena = try self.arena_pool.acquire();
    errdefer self.arena_pool.release(arena);

    const encoding = form_element.getAttributeSafe(comptime .wrap("enctype"));

    var buf = std.Io.Writer.Allocating.init(arena);
    try form_data.write(encoding, &buf.writer);

    const method = form_element.getAttributeSafe(comptime .wrap("method")) orelse "";
    var action = form_element.getAttributeSafe(comptime .wrap("action")) orelse self.url;

    var opts = NavigateOpts{
        .reason = .form,
        .kind = .{ .push = null },
    };
    if (std.ascii.eqlIgnoreCase(method, "post")) {
        opts.method = .POST;
        opts.body = buf.written();
        // form_data.write currently only supports this encoding, so we know this has to be the content type
        opts.header = "Content-Type: application/x-www-form-urlencoded";
    } else {
        action = try URL.concatQueryString(arena, action, buf.written());
    }
    return self.scheduleNavigationWithArena(arena, action, opts, .form);
}

// insertText is a shortcut to insert text into the active element.
pub fn insertText(self: *Page, v: []const u8) !void {
    const html_element = self.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        return input.innerInsert(v, self);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        return textarea.innerInsert(v, self);
    }
}

const RequestCookieOpts = struct {
    is_http: bool = true,
    is_navigation: bool = false,
};
pub fn requestCookie(self: *const Page, opts: RequestCookieOpts) Http.Client.RequestCookie {
    return .{
        .jar = &self._session.cookie_jar,
        .origin = self.url,
        .is_http = opts.is_http,
        .is_navigation = opts.is_navigation,
    };
}

fn asUint(comptime string: anytype) std.meta.Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @sizeOf(@TypeOf(string.*)) - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const testing = @import("../testing.zig");
test "WebApi: Page" {
    try testing.htmlRunner("page", .{});
}

test "WebApi: Frames" {
    try testing.htmlRunner("frames", .{});
}

test "WebApi: Integration" {
    try testing.htmlRunner("integration", .{});
}

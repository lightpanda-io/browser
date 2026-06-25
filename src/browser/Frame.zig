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

const JS = @import("js/js.zig");
const Mime = @import("Mime.zig");
const Page = @import("Page.zig");
const Factory = @import("Factory.zig");
const Session = @import("Session.zig");
const EventManager = @import("EventManager.zig");
const ScriptManager = @import("ScriptManager.zig");
const StyleManager = @import("StyleManager.zig");

const Parser = @import("parser/Parser.zig");
const h5e = @import("parser/html5ever.zig");

const CustomElementReactions = @import("CustomElementReactions.zig");

const URL = @import("URL.zig");
const Blob = @import("webapi/Blob.zig");
const FileList = @import("webapi/FileList.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const Text = @import("webapi/cdata/Text.zig");
const Element = @import("webapi/Element.zig");
const HtmlElement = @import("webapi/element/Html.zig");
const Window = @import("webapi/Window.zig");
const Location = @import("webapi/Location.zig");
const Document = @import("webapi/Document.zig");
const ShadowRoot = @import("webapi/ShadowRoot.zig");
const Performance = @import("webapi/Performance.zig");
const Screen = @import("webapi/Screen.zig");
const VisualViewport = @import("webapi/VisualViewport.zig");
const AbstractRange = @import("webapi/AbstractRange.zig");
const MutationObserver = @import("webapi/MutationObserver.zig");
const IntersectionObserver = @import("webapi/IntersectionObserver.zig");
const Worker = @import("webapi/Worker.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const CustomElementDefinition = @import("webapi/CustomElementDefinition.zig");
const PageTransitionEvent = @import("webapi/event/PageTransitionEvent.zig");
const SubmitEvent = @import("webapi/event/SubmitEvent.zig");
const HashChangeEvent = @import("webapi/event/HashChangeEvent.zig");
const popover = @import("webapi/element/popover.zig");
const slotting = @import("webapi/element/slotting.zig");
const NavigationKind = @import("webapi/navigation/root.zig").NavigationKind;

const HttpClient = @import("HttpClient.zig");
const sys_url = @import("../sys/url.zig");

const timestamp = @import("../datetime.zig").timestamp;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

const GlobalEventHandlersLookup = @import("webapi/global_event_handlers.zig").Lookup;

pub const observers = @import("frame/observers.zig");
pub const user_input = @import("frame/user_input.zig");
pub const node_factory = @import("frame/node_factory.zig");

const log = lp.log;
const String = lp.String;
const IFrame = Element.Html.IFrame;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

pub const BUF_SIZE = 1024;

const Frame = @This();

// This is the "id" of the frame. It can be re-used from frame-to-frame, e.g.
// when navigating.
_frame_id: u32,

// This is the "id" of this specific instance of the frame. It changes on every
// navigate.
_loader_id: u32,

_page: *Page,

_session: *Session,

_event_manager: EventManager,

_parse_mode: enum { document, fragment, document_write } = .document,

// While fragment-parsing (e.g. innerHTML), scripts are normally marked
// "already started" so they never run. The one exception is
// Range.createContextualFragment(), whose scripts DO run when the fragment is
// inserted into a document
_fragment_scripts_runnable: bool = false,

// See Attribute.List for what this is. TL;DR: proper DOM Attribute Nodes are
// fat yet rarely needed. We only create them on-demand, but still need proper
// identity (a given attribute should return the same *Attribute), so we do
// a look here. We don't store this in the Element or Attribute.List.Entry
// because that would require additional space per element / Attribute.List.Entry
// even though we'll create very few (if any) actual *Attributes.
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
_element_scroll_positions: Element.ScrollPositionLookup = .empty,
_element_namespace_uris: Element.NamespaceUriLookup = .empty,

// Same as above, but for Nodes (slot assigments apply to both Element AND
// Text nodes)
_assigned_slots: Node.AssignedSlotLookup = .empty,
_manual_slot_assignments: Node.AssignedSlotLookup = .empty,

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
_event_target_attr_listeners: GlobalEventHandlersLookup = .empty,

// Blob URL registry for URL.createObjectURL/revokeObjectURL
_blob_urls: std.StringHashMapUnmanaged(*Blob) = .{},

// FileLists owned by `<input type=file>` elements. Each holds refs on its
// File objects (reference counted via their Blob proto); released at teardown.
_file_lists: std.ArrayList(*FileList) = .{},

/// Element `load`/`error` events queued to fire on the next scheduler tick,
/// and flushed before window's `load` event.
/// A call to `documentIsComplete` (which calls `_documentIsComplete`) resets it.
/// Double-buffered so that dispatching events (which may trigger JS that
/// creates new elements) doesn't invalidate the list while iterating.
_queued_events_1: std.ArrayList(QueuedEvent) = .{},
_queued_events_2: std.ArrayList(QueuedEvent) = .{},
_queued_events: *std.ArrayList(QueuedEvent) = undefined,

_style_manager: StyleManager,
_script_manager: ScriptManager,

_http_owner: HttpClient.Owner = .{},

// List of active live ranges (for mutation updates per DOM spec)
_live_ranges: std.DoublyLinkedList = .{},

// List of open BroadcastChannels, used to route postMessage between same-named
// channels in this frame's origin
_broadcast_channels: std.DoublyLinkedList = .{},

// MutationObserver / IntersectionObserver bookkeeping. See frame/observers.zig.
_mutation: observers.Mutation = .{},
_intersection: observers.Intersection = .{},

// Slots that need slotchange events to be fired, in signal order. Delivered
// by deliverMutations because there is specific timing with for these events
// with respect to mutations
_slots_pending_slotchange: std.AutoArrayHashMapUnmanaged(*Element.Html.Slot, void) = .{},

// Lookup for customized built-in elements. Maps element pointer to definition.
_customized_builtin_definitions: std.AutoHashMapUnmanaged(*Element, *CustomElementDefinition) = .{},
_customized_builtin_connected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},
_customized_builtin_disconnected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},

// This is set when an element is being upgraded (constructor is called).
// The constructor can access this to get the element being upgraded.
_upgrading_element: ?*Node = null,

// List of custom elements that were created before their definition was registered
_undefined_custom_elements: std.ArrayList(*Element.Html.Custom) = .{},

// Pending custom-element reactions (connected/disconnected/adopted/attribute
// changed). Reactions are enqueued during DOM mutation and drained at the
// outer algorithm boundary — set up by the JS bridge for [CEReactions]
// methods and by the parser pump on each yield.
_ce_reactions: CustomElementReactions,

// for heap allocations and managing WebAPI objects
_factory: *Factory,

_load_state: LoadState = .waiting,

_parse_state: ParseState = .pre,

/// `frameErrorCallback` swallows the failure into a placeholder page;
/// callers that need to detect it read this.
_last_navigate_error: ?anyerror = null,

_notified_network_idle: IdleNotification = .init,
_notified_network_almost_idle: IdleNotification = .init,

// A navigation event that happens from a script gets scheduled to run on the
// next tick.
_queued_navigation: ?*QueuedNavigation = null,

// The URL of the current frame
url: [:0]const u8 = "about:blank",

origin: ?[]const u8 = null,

// The base url specifies the base URL used to resolve the relative urls.
// It is set by a <base> tag.
// If null the url must be used.
base_url: ?[:0]const u8 = null,

// referer header cache.
referer_header: ?[:0]const u8 = null,

// Document charset (canonical name from encoding_rs, static lifetime)
charset: []const u8 = "UTF-8",

// Arbitrary buffer. Need to temporarily lowercase a value? Use this. No lifetime
// guarantee - it's valid until someone else uses it.
buf: [BUF_SIZE]u8 = undefined,

// access to the JavaScript engine
js: *JS.Context,

// An arena for the lifetime of the frame.
arena: Allocator,

// An arena with a lifetime guaranteed to be for 1 invoking of a Zig function
// from JS. Best arena to use, when possible.
call_arena: Allocator,

parent: ?*Frame,
window: *Window,
document: *Document,
iframe: ?*IFrame = null,

child_frames_sorted: bool = true,
child_frames: std.ArrayList(*Frame) = .{},

// Workers created by this frame. Cleaned up when frame is destroyed.
workers: std.ArrayList(*Worker) = .{},

// This is maybe not great. It's a counter on the number of events that we're
// waiting on before triggering the "load" event. Essentially, we need all
// synchronous scripts and all iframes to be loaded. Scripts are handled by the
// ScriptManager, so all scripts just count as 1 pending load.
_pending_loads: u32,

_parent_notified: bool = false,

_type: enum { root, frame }, // only used for logs right now
_req_id: u32 = 0,
_navigated_options: ?NavigatedOpts = null,
_http_status: ?u16 = null,
_http_headers: std.ArrayList(HttpHeader) = .empty,

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const InitOpts = struct {
    parent: ?*Frame = null,

    // When a frame/popup re-navigates, we should preserve the same window.
    // There are a couple reasons for this. First, iframe.contentWindow should
    // maintain the same identity. Secondly, a reference to the window can be
    // acquired prior to navigation, and then used after. So it should remain valid.
    reuse_window: ?*Window = null,
};

pub fn init(self: *Frame, frame_id: u32, page: *Page, opts: InitOpts) !void {
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.init", .{});
    }

    const parent = opts.parent;

    const session = page.session;
    const call_arena = try session.getArena(.medium, "call_arena");
    errdefer session.releaseArena(call_arena);

    const factory = &page.factory;
    const document = (try factory.document(Node.Document.HTMLDocument{
        ._proto = undefined,
    })).asDocument();

    const arena = page.frame_arena;

    self.* = .{
        .js = undefined,
        .arena = arena,
        .parent = parent,
        .document = document,
        .window = undefined,
        .call_arena = call_arena,
        ._frame_id = frame_id,
        ._page = page,
        ._session = session,
        ._loader_id = session.nextLoaderId(),
        ._factory = factory,
        ._pending_loads = 1, // always 1 for the ScriptManager
        ._type = if (parent == null) .root else .frame,
        ._style_manager = undefined,
        ._script_manager = undefined,
        ._ce_reactions = .{ .allocator = arena },
        ._event_manager = EventManager.init(arena, self),
    };
    self._queued_events = &self._queued_events_1;
    self._http_owner.blob_urls = &self._blob_urls;

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

    const window_template = Window{
        ._frame = self,
        ._proto = undefined,
        ._document = self.document,
        ._location = undefined,
        ._performance = .init(),
        ._screen = screen,
        ._visual_viewport = visual_viewport,
        ._cross_origin_wrapper = undefined,
    };

    if (opts.reuse_window) |w| {
        const proto = w._proto;
        w.* = window_template;
        w._proto = proto;
        self.window = w;
    } else {
        self.window = try factory.eventTarget(window_template);
    }
    self.window._cross_origin_wrapper = .{ .window = self.window };

    self._style_manager = try StyleManager.init(self);
    errdefer self._style_manager.deinit();

    const browser = session.browser;
    self._script_manager = ScriptManager.init(browser.allocator, &browser.http_client, self);
    errdefer self._script_manager.deinit();

    self.js = try browser.env.createContext(self, .{
        .identity = &page.identity,
        .identity_arena = arena,
        .call_arena = self.call_arena,
    });
    errdefer browser.env.destroyContext(self.js);

    const location = try Location.init("about:blank", self);
    // We're holding a reference in Zig-side.
    location.acquireRef();
    self.window._location = location;

    document._frame = self;

    if (comptime builtin.is_test == false) {
        if (parent == null) {
            // HTML test runner manually calls these as necessary
            try self.js.scheduler.add(session.browser, struct {
                fn runIdleTasks(ctx: *anyopaque) !?u32 {
                    const b: *@import("Browser.zig") = @ptrCast(@alignCast(ctx));
                    b.runIdleTasks();
                    return 200;
                }
            }.runIdleTasks, 200, .{ .name = "frame.runIdleTasks", .low_priority = true });
        }
    }
}

pub fn deinit(self: *Frame) void {
    for (self.child_frames.items) |frame| {
        frame.deinit();
    }

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.deinit", .{ .url = self.url, .type = self._type });

        // Uncomment if you want slab statistics to print.
        // const stats = self._factory._slab.getStats(self.arena) catch unreachable;
        // var buffer: [256]u8 = undefined;
        // var stream = std.fs.File.stderr().writer(&buffer).interface;
        // stats.print(&stream) catch unreachable;
    }

    self._parse_state.deinit(self);

    // Unregister CookieStore from session notifications before the JS
    // context (and thus the scheduler) is destroyed, otherwise a late
    // mutation could schedule a callback that never runs.
    if (self.window._cookie_store) |cs| cs.detach();

    const page = self._page;

    if (self._queued_navigation) |qn| {
        page.releaseArena(qn.arena);
    }

    {
        // Release all objects we're referencing
        {
            var it = self._blob_urls.valueIterator();
            while (it.next()) |blob| {
                blob.*.releaseRef(page);
            }
        }

        for (self._file_lists.items) |file_list| {
            for (file_list._files) |file| {
                file._proto.releaseRef(page);
            }
        }

        observers.deinit(self, page);

        var document = self.window._document;
        document._selection.releaseRef(page);

        if (document._fonts) |f| {
            f.releaseRef(page);
        }

        // Release our reference to location.
        self.window._location.releaseRef(page);
    }

    const browser = page.session.browser;

    browser.http_client.abortOwner(&self._http_owner);

    browser.env.destroyContext(self.js);

    // Must be after context is destroyed. A finalizer can reach into the *Worker
    // (e.g. Worker.ReceiveMessageCallback) so the worker must still be valid.
    for (self.workers.items) |worker| {
        worker.deinit();
    }

    self._script_manager.base.shutdown = true;

    self._script_manager.deinit();
    self._style_manager.deinit();

    page.releaseArena(self.call_arena);
}

pub fn trackWorker(self: *Frame, worker: *Worker) !void {
    try self.workers.append(self.arena, worker);
}

pub fn removeWorker(self: *Frame, worker: *Worker) void {
    for (self.workers.items, 0..) |w, i| {
        if (w == worker) {
            _ = self.workers.swapRemove(i);
            break;
        }
    }
}

pub fn base(self: *const Frame) [:0]const u8 {
    return self.base_url orelse self.url;
}

pub fn getTitle(self: *Frame) !?[]const u8 {
    if (self.window._document.is(Document.HTMLDocument)) |html_doc| {
        return try html_doc.getTitle(self);
    }
    return null;
}

pub const HttpMetadata = struct {
    url: [:0]const u8,
    status: ?u16,
    headers: []const HttpHeader,
};

pub fn httpMetadata(self: *const Frame) HttpMetadata {
    return .{
        .url = self.url,
        .status = self._http_status,
        .headers = self._http_headers.items,
    };
}

// Add common headers for a request:
// * referer
pub fn headersForRequest(self: *Frame, headers: *HttpClient.Headers) !void {
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

pub fn getArena(self: *Frame, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self._session.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *Frame, allocator: Allocator) void {
    return self._session.releaseArena(allocator);
}

pub fn isSameOrigin(self: *const Frame, url: [:0]const u8) bool {
    const current_origin = self.origin orelse return false;

    // fastpath
    if (!std.mem.startsWith(u8, url, current_origin)) {
        return false;
    }

    // Starting here, at least protocols are equals.
    // Compare hosts (domain:port) strictly
    return std.mem.eql(u8, URL.getHost(url), URL.getHost(current_origin));
}

pub fn navigate(self: *Frame, request_url: [:0]const u8, opts: NavigateOpts) !void {
    lp.assert(self._load_state == .waiting, "frame.renavigate", .{});
    const session = self._session;
    self._load_state = .parsing;
    self._last_navigate_error = null;

    const req_id = self._session.browser.http_client.nextReqId();
    log.info(.frame, "navigate", .{
        .url = request_url,
        .method = opts.method,
        .reason = opts.reason,
        .body = opts.body != null,
        .req_id = req_id,
        .type = self._type,
    });

    // Handle synthetic navigations: about:blank and blob: URLs
    const is_about_blank = std.mem.eql(u8, "about:blank", request_url);
    const is_blob = !is_about_blank and std.mem.startsWith(u8, request_url, "blob:");

    if (is_about_blank or is_blob) {
        self.url = if (is_about_blank) "about:blank" else try self.arena.dupeZ(u8, request_url);

        // even though about:blank navigations may share the same _data_, we
        // have to do this to make sure window.location is at a unique _address_.
        // If we don't do this, multiple window._location will have the same
        // address and thus be mapped to the same v8::Object in the identity map.
        const location = try Location.init(self.url, self);
        location.acquireRef();
        // We're not holding a ref to old location anymore.
        self.window._location.releaseRef(self._page);
        self.window._location = location;

        if (is_blob) {
            // strip out blob:
            self.origin = try URL.getOrigin(self.arena, request_url[5.. :0]);
        } else if (self.parent) |parent| {
            self.origin = parent.origin;
            if (is_about_blank) {
                self.base_url = parent.base();
            }
        } else if (self.window._opener) |opener| {
            self.origin = opener._frame.origin;
            if (is_about_blank) {
                self.base_url = opener._frame.base();
            }
        } else {
            self.origin = null;
        }
        try self.js.setOrigin(self.origin);

        // Assume we parsed the document.
        // It's important to force a reset during the following navigation.
        self._parse_state = .complete;

        // Content injection
        if (is_blob) {
            // For navigation, walk up the parent chain to find blob URLs
            // (e.g., parent creates blob URL and sets iframe.src to it)
            const blob = blk: {
                var current: ?*Frame = self.parent;
                while (current) |frame| {
                    if (frame._blob_urls.get(request_url)) |b| break :blk b;
                    current = frame.parent;
                }
                log.warn(.js, "invalid blob", .{ .url = request_url });
                return error.BlobNotFound;
            };
            const parse_arena = try self.getArena(.medium, "Frame.parseBlob");
            defer self.releaseArena(parse_arena);
            var parser = Parser.init(parse_arena, self.document.asNode(), self, .{ .allow_declarative_shadow = true });
            parser.parse(blob._slice);
        } else {
            self.document.injectBlank(self) catch |err| {
                log.err(.browser, "inject blank", .{ .err = err });
                return error.InjectBlankFailed;
            };
        }

        session.notification.dispatch(.frame_navigate, &.{
            .opts = opts,
            .req_id = req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        // Record telemetry for navigation
        session.browser.app.telemetry.record(.{
            .navigate = .{
                .tls = false, // about:blank and blob: are not TLS
                .proxy = session.browser.app.config.httpProxy() != null,
            },
        });

        session.notification.dispatch(.frame_navigated, &.{
            .req_id = req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
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

        if (self.parent == null) {
            session.navigation._current_navigation_kind = opts.kind;
            try session.navigation.commitNavigation(self);
        }

        self.documentIsComplete();
        return;
    }

    const http_client = &session.browser.http_client;

    self._http_status = null;
    self._http_headers = .empty;

    self.url = blk: {
        if (URL.isCompleteHTTPUrl(request_url)) {
            break :blk try self.arena.dupeZ(u8, request_url);
        }
        break :blk try std.mem.concatWithSentinel(self.arena, u8, &.{ "http://", request_url }, 0);
    };
    self.origin = try URL.getOrigin(self.arena, self.url);

    self._req_id = req_id;
    self._navigated_options = .{
        .cdp_id = opts.cdp_id,
        .reason = opts.reason,
        .method = opts.method,
        .body = if (opts.body) |b| try self.arena.dupe(u8, b) else null,
        .header = if (opts.header) |h| try self.arena.dupeZ(u8, h) else null,
    };

    var headers = try http_client.newHeaders();
    try headers.add(lp.Config.HttpHeaders.navigation_accept);
    if (opts.header) |hdr| {
        try headers.add(hdr);
    }
    if (opts.referer) |ref| {
        const ref_header = try std.mem.concatWithSentinel(self.arena, u8, &.{ "Referer: ", ref }, 0);
        try headers.add(ref_header);
    }

    // A root navigation issued against a pending Page (i.e. one allocated by
    // Session.initiateRootNavigation) flags both the notification and the
    // HTTP request itself: CDP skips its node-registry reset until commit,
    // and the in-flight transfer survives the OLD page's frame.deinit which
    // calls http_client.abortList() on the shared frame_id during
    // commitPendingPage.
    const is_pending_root = self._page.replaces != null;

    // We dispatch frame_navigate event before sending the request.
    // It ensures the event frame_navigated is not dispatched before this one.
    session.notification.dispatch(.frame_navigate, &.{
        .opts = opts,
        .url = self.url,
        .req_id = req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
        .is_pending_root = is_pending_root,
    });

    // Record telemetry for navigation
    session.browser.app.telemetry.record(.{ .navigate = .{
        .tls = std.ascii.startsWithIgnoreCase(self.url, "https://"),
        .proxy = session.browser.app.config.httpProxy() != null,
    } });

    session.navigation._current_navigation_kind = opts.kind;

    self.makeRequest(.{
        .ctx = self,
        .url = self.url,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .method = opts.method,
        .headers = headers,
        .body = opts.body,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = opts.initiator_url orelse self.url,
        .resource_type = .document,
        .notification = self._session.notification,
        .header_callback = frameHeaderDoneCallback,
        .data_callback = frameDataCallback,
        .done_callback = frameDoneCallback,
        .error_callback = frameErrorCallback,
    }) catch |err| {
        log.err(.frame, "navigate request", .{ .url = self.url, .err = err, .type = self._type });
        return err;
    };
}

// Navigation can happen in many places, such as executing a <script> tag or
// a JavaScript callback, a CDP command, etc...It's rarely safe to do immediately
// as the caller almost certainly doesn't expect the frame to go away during the
// call. So, we schedule the navigation for the next tick.
pub fn scheduleNavigation(self: *Frame, request_url: []const u8, opts: NavigateOpts, nt: Navigation) !void {
    if (self.canScheduleNavigation(std.meta.activeTag(nt)) == false) {
        return;
    }
    const arena = try self._session.getArena(.small, "scheduleNavigation");
    errdefer self._session.releaseArena(arena);
    return self.scheduleNavigationWithArena(arena, request_url, opts, nt);
}

// Don't name the first parameter "self", because the target of this navigation
// might change inside the function. So the code should be explicit about the
// frame that it's acting on.
fn scheduleNavigationWithArena(originator: *Frame, arena: Allocator, request_url: []const u8, opts: NavigateOpts, nt: Navigation) !void {
    const resolved_url, const is_about_blank = blk: {
        if (URL.isCompleteHTTPUrl(request_url)) {
            break :blk .{ try arena.dupeZ(u8, request_url), false };
        }

        if (std.mem.eql(u8, request_url, "about:blank")) {
            // navigate will handle this special case
            break :blk .{ "about:blank", true };
        }

        // request_url isn't a "complete" URL, so it has to be resolved with the
        // originator's base. Unless, originator's base is "about:blank", in which
        // case we have to walk up the parents and find a real base.
        const frame_base = base_blk: {
            var maybe_not_blank_frame = originator;
            while (true) {
                const maybe_base = maybe_not_blank_frame.base();
                if (std.mem.eql(u8, maybe_base, "about:blank") == false) {
                    break :base_blk maybe_base;
                }
                // The orelse here is probably an invalid case, but there isn't
                // anything we can do about it. It should never happen?
                maybe_not_blank_frame = maybe_not_blank_frame.parent orelse break :base_blk "";
            }
        };

        const u = try URL.resolve(
            arena,
            frame_base,
            request_url,
            .{ .always_dupe = true, .encoding = originator.charset },
        );
        break :blk .{ u, false };
    };

    const target = switch (nt) {
        .form, .anchor => |p| p,
        .script => |p| p orelse originator,
        .iframe => |iframe| iframe._window.?._frame, // only an frame with existing content (i.e. a window) can be navigated
    };

    const session = target._session;
    // Short-circuit only true fragment-only navigations (same path/query, different
    // fragment). Identical URLs fall through and trigger a real reload.
    const is_fragment_navigation = !std.mem.eql(u8, target.url, resolved_url) and URL.eqlDocument(target.url, resolved_url);
    if (!opts.force and is_fragment_navigation) {
        const old_url = target.url;
        target.url = try target.arena.dupeZ(u8, resolved_url);

        const location = try Location.init(target.url, target);
        location.acquireRef();
        target.window._location.releaseRef(target._page);
        target.window._location = location;

        if (target.parent == null) {
            try session.navigation.updateEntries(target.url, opts.kind, target, true);
        }

        try target.queueHashChange(old_url, target.url);

        // don't defer this, the caller is responsible for freeing it on error
        session.releaseArena(arena);
        return;
    }

    log.info(.browser, "schedule navigation", .{
        .url = resolved_url,
        .reason = opts.reason,
        .type = target._type,
    });

    // Navigation: kill in-flight HTTP transfers, but leave WebSockets
    // alive — they're cross-document by spec.
    session.browser.http_client.abortRequests(&target._http_owner);

    // Capture the originating frame's URL as the Referer for this
    // navigation. The originator's frame may be torn down before navigate()
    // runs (processRootQueuedNavigation rebuilds the Page in-place), so dup
    // into the QueuedNavigation arena which outlives that tear-down.
    var nav_opts = opts;
    if (std.mem.startsWith(u8, originator.url, "http")) {
        // The same dup feeds two purposes: Referer header (subject to
        // Referrer-Policy in the future) and SameSite computation (which
        // must use the real initiator regardless of policy). We share the
        // same allocation for both.
        const dup = try arena.dupeZ(u8, originator.url);
        if (nav_opts.referer == null) {
            nav_opts.referer = dup;
        }
        if (nav_opts.initiator_url == null) {
            nav_opts.initiator_url = dup;
        }
    }

    const qn = try arena.create(QueuedNavigation);
    qn.* = .{
        .opts = nav_opts,
        .arena = arena,
        .url = resolved_url,
        .is_about_blank = is_about_blank,
        .navigation_type = std.meta.activeTag(nt),
    };

    if (target._queued_navigation) |existing| {
        session.releaseArena(existing.arena);
    }

    target._queued_navigation = qn;
    return session.scheduleNavigation(target);
}

// A script can have multiple competing navigation events, say it starts off
// by doing top.location = 'x' and then does a form submission.
// You might think that we just stop at the first one, but that doesn't seem
// to be what browsers do, and it isn't particularly well supported by v8 (i.e.
// halting execution mid-script).
// From what I can tell, there are 4 "levels" of priority, in order:
// 1 - form submission
// 2 - JavaScript apis (e.g. top.location)
// 3 - anchor clicks
// 4 - iframe.src =
// Within, each category, it's last-one-wins.
fn canScheduleNavigation(self: *Frame, new_target_type: NavigationType) bool {
    if (self.parent) |parent| {
        if (parent.isGoingAway()) {
            return false;
        }
    }

    const existing_target_type = (self._queued_navigation orelse return true).navigation_type;

    if (existing_target_type == new_target_type) {
        // same reason, than this latest one wins
        return true;
    }

    return switch (existing_target_type) {
        .iframe => true, // everything is higher priority than iframe.src = "x"
        .anchor => new_target_type != .iframe, // an anchor is only higher priority than an iframe
        .form => false, // nothing is higher priority than a form
        .script => new_target_type == .form, // a form is higher priority than a script
    };
}

pub fn makeRequest(self: *Frame, req: HttpClient.Request) !void {
    return self._session.browser.http_client.request(req, &self._http_owner);
}

// Synchronously abort every transfer and WebSocket owned by this frame
// and all of its descendants.
pub fn abortTransfers(self: *Frame) void {
    for (self.child_frames.items) |child| {
        child.abortTransfers();
    }
    const http_client = &self._session.browser.http_client;
    http_client.abortOwner(&self._http_owner);
    // abortOwner misses deferred contexts whose transfer already completed.
    http_client.deferring_layer.cancelFrame(self._frame_id);
}

pub fn documentIsLoaded(self: *Frame) void {
    if (self._load_state != .parsing) {
        // Ideally, documentIsLoaded would only be called once, but if a
        // script is dynamically added from an async script after
        // documentIsLoaded is already called, then ScriptManager will call
        // it again.
        return;
    }

    self._load_state = .load;
    self.document._ready_state = .interactive;
    self._documentIsLoaded() catch |err| switch (err) {
        error.JsException => {}, // already logged
        else => log.err(.frame, "document is loaded2", .{ .err = err, .type = self._type, .url = self.url }),
    };
}

pub fn _documentIsLoaded(self: *Frame) !void {
    try self.dispatchReadyStateChange();

    const event = try Event.initTrusted(.wrap("DOMContentLoaded"), .{ .bubbles = true }, self._page);
    try self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    );

    self._session.notification.dispatch(.frame_dom_content_loaded, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

// Fired at the document on every change to document.readyState: before
// DOMContentLoaded (readiness -> interactive) and before the load event
// (readiness -> complete). Does not bubble.
// https://html.spec.whatwg.org/multipage/dom.html#current-document-readiness
fn dispatchReadyStateChange(self: *Frame) !void {
    const event = try Event.initTrusted(.wrap("readystatechange"), .{}, self._page);
    try self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    );
}

pub fn scriptsCompletedLoading(self: *Frame) void {
    self.pendingLoadCompleted();
}

pub fn iframeCompletedLoading(self: *Frame, iframe: *IFrame) void {
    // When parsing HTML, fire any load event for an iframe on the next tick.
    const parsing_html = switch (self._parse_state) {
        .html => true,
        else => false,
    };
    if (parsing_html and iframe._src.len > 0) {
        self.queueElementEvent(iframe._proto, .load) catch |err| {
            log.err(.frame, "iframe queue load", .{ .err = err, .url = iframe._src });
        };
        self.pendingLoadCompleted();
        return;
    }

    var hs: JS.HandleScope = undefined;
    const entered = self.js.enter(&hs);
    defer entered.exit();

    blk: {
        const event = Event.initTrusted(comptime .wrap("load"), .{}, self._page) catch |err| {
            log.err(.frame, "iframe event init", .{ .err = err, .url = iframe._src });
            break :blk;
        };
        self._event_manager.dispatch(iframe.asNode().asEventTarget(), event) catch |err| {
            log.warn(.js, "iframe onload", .{ .err = err, .url = iframe._src });
        };
    }

    self.pendingLoadCompleted();
}

fn pendingLoadCompleted(self: *Frame) void {
    const pending_loads = self._pending_loads;
    if (pending_loads == 1) {
        self._pending_loads = 0;
        self.documentIsComplete();
    } else {
        self._pending_loads = pending_loads - 1;
    }
}

pub fn documentIsComplete(self: *Frame) void {
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
    self._documentIsComplete() catch |err| switch (err) {
        error.JsException => {}, // already logged
        else => log.err(.frame, "document is complete", .{ .err = err, .type = self._type, .url = self.url }),
    };
}

fn _documentIsComplete(self: *Frame) !void {
    self.document._ready_state = .complete;
    try self.dispatchReadyStateChange();

    // Run element load/error events before window.load.
    try self.dispatchQueuedEvents();

    // Dispatch window.load event.
    const window_target = self.window.asEventTarget();
    if (self._event_manager.hasDirectListeners(window_target, "load", self.window._on_load)) {
        const event = try Event.initTrusted(comptime .wrap("load"), .{}, self._page);
        // This event is weird, it's dispatched directly on the window, but
        // with the document as the target.
        event._target = self.document.asEventTarget();
        try self._event_manager.dispatchDirect(window_target, event, self.window._on_load, .{ .inject_target = false, .context = "page load" });
    }

    self._session.notification.dispatch(.frame_loaded, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });

    if (self._event_manager.hasDirectListeners(window_target, "pageshow", self.window._on_pageshow)) {
        const pageshow_event = (try PageTransitionEvent.initTrusted(comptime .wrap("pageshow"), .{}, self)).asEvent();
        try self._event_manager.dispatchDirect(window_target, pageshow_event, self.window._on_pageshow, .{ .context = "page show" });
    }

    if (comptime IS_DEBUG) {
        log.debug(.frame, "load", .{ .url = self.url, .type = self._type });
    }

    self.notifyParentLoadComplete();
}

fn notifyParentLoadComplete(self: *Frame) void {
    const parent = self.parent orelse return;

    if (self._parent_notified == true) {
        if (comptime IS_DEBUG) {
            std.debug.assert(false);
        }
        // shouldn't happen, don't want to crash a release build over it
        return;
    }

    self._parent_notified = true;
    parent.iframeCompletedLoading(self.iframe.?);
}

fn frameHeaderDoneCallback(response: HttpClient.Response) !HttpClient.HeaderResult {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

    // Commit point for a pending root navigation. The session has been
    // holding the OLD page alive during the round-trip; now that response
    // headers have arrived, swap pending → active. This dispatches
    // frame_remove (clears OLD V8 context group + CDP node_registry),
    // tears down the OLD page, flips the pointer, and dispatches
    // frame_created against the new (now active) frame.
    if (self._page.replaces != null) {
        try self._session.commitPendingPage(self._page);
    }

    const response_url = response.url();
    if (std.mem.eql(u8, response_url, self.url) == false) {
        // would be different than self.url in the case of a redirect
        self.url = try self.arena.dupeZ(u8, response_url);
        self.origin = try URL.getOrigin(self.arena, self.url);
    }
    try self.js.setOrigin(self.origin);

    // After any redirect, drop the original method/body/header so a later
    // Page.reload doesn't re-POST form data to the redirect target. Conservative
    // default — 307/308 technically preserve the method per RFC 7231, but
    // resubmitting form data is the more dangerous failure mode.
    if ((response.redirectCount() orelse 0) > 0) {
        if (self._navigated_options) |*no| {
            no.method = .GET;
            no.body = null;
            no.header = null;
        }
    }

    // Init new location.
    const location = try Location.init(self.url, self);
    location.acquireRef();
    self.window._location.releaseRef(self._page);
    self.window._location = location;

    if (comptime IS_DEBUG) {
        log.debug(.frame, "navigate header", .{
            .url = self.url,
            .status = response.status(),
            .content_type = response.contentType(),
            .type = self._type,
        });
    }

    self._http_status = response.status();
    var it = response.headerIterator();
    while (it.next()) |hdr| {
        try self._http_headers.append(self.arena, .{
            .name = try self.arena.dupe(u8, hdr.name),
            .value = try self.arena.dupe(u8, hdr.value),
        });
    }

    if (self._navigated_options) |no| {
        // _navigated_options will be null in special short-circuit cases, like
        // "navigating" to about:blank, in which case this notification has
        // already been sent
        self._session.notification.dispatch(.frame_navigated, &.{
            .opts = no,
            .url = self.url,
            .req_id = self._req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .timestamp = timestamp(.monotonic),
        });
    }

    // If the response is a file download, stream its body to disk instead of
    // parsing it as a page. This sets _parse_state to .download, which the
    // data/done callbacks below special-case.
    _ = try self.maybeStartDownload(response);

    return .proceed;
}

// Returns true when the response was set up as a file download. A response is
// treated as a download when Browser.setDownloadBehavior opted in
// (allow/allowAndName) and the response carries Content-Disposition: attachment.
// See issue #2701.
fn maybeStartDownload(self: *Frame, response: HttpClient.Response) !bool {
    const session = self._session;
    switch (session.download_behavior) {
        .allow, .allow_and_name => {},
        .deny => return false,
    }

    const disposition: HttpClient.Header = blk: {
        var it = response.headerIterator();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-disposition")) {
                break :blk hdr;
            }
        }
        return false;
    };
    if (std.ascii.eqlIgnoreCase(disposition.firstValue(), "attachment") == false) {
        return false;
    }

    const download_path = session.download_path orelse {
        log.warn(.frame, "download without downloadPath", .{ .url = self.url });
        return false;
    };

    // `guid` is the CDP "Global Unique Identifier" that ties the
    // downloadWillBegin / downloadProgress events to one download.
    var guid_buf: [36]u8 = undefined;
    @import("../id.zig").uuidv4(&guid_buf);
    const guid = try self.arena.dupe(u8, &guid_buf);

    const suggested = dispositionFilename(disposition) orelse (try urlBasename(self.arena, self.url)) orelse guid;
    const suggested_filename = try self.arena.dupe(u8, suggested);

    // allowAndName stores the file under its guid; allow uses the suggested name.
    const on_disk_name = switch (session.download_behavior) {
        .allow_and_name => guid,
        else => suggested_filename,
    };

    std.fs.cwd().makePath(download_path) catch |err| {
        log.err(.frame, "download makePath", .{ .err = err, .path = download_path });
        return false;
    };
    var dir = std.fs.cwd().openDir(download_path, .{}) catch |err| {
        log.err(.frame, "download openDir", .{ .err = err, .path = download_path });
        return false;
    };
    defer dir.close();
    const file = dir.createFile(on_disk_name, .{ .truncate = true }) catch |err| {
        log.err(.frame, "download createFile", .{ .err = err, .name = on_disk_name });
        return false;
    };

    const total: ?u64 = if (response.contentLength()) |cl| cl else null;

    self._parse_state = .{ .download = .{
        .guid = guid,
        .file = file,
        .filename = suggested_filename,
        .received = 0,
        .total = total,
    } };

    if (session.download_events_enabled) {
        session.notification.dispatch(.download_will_begin, &.{
            .frame_id = self._frame_id,
            .guid = guid,
            .url = self.url,
            .suggested_filename = suggested_filename,
        });
        session.notification.dispatch(.download_progress, &.{
            .guid = guid,
            .total_bytes = total orelse 0,
            .received_bytes = 0,
            .state = .in_progress,
        });
    }

    return true;
}

// Extracts the filename from a Content-Disposition header, handling the quoted,
// unquoted, and RFC 5987 (filename*=charset''value) forms. Path components are
// stripped so the result is always a bare basename.
fn dispositionFilename(disposition: HttpClient.Header) ?[]const u8 {
    // Prefer the extended filename*= form when present, per RFC 6266.
    if (disposition.param("filename*")) |ext| {
        // charset'lang'value — take everything after the second quote.
        if (std.mem.indexOfScalar(u8, ext, '\'')) |first| {
            if (std.mem.indexOfScalarPos(u8, ext, first + 1, '\'')) |second| {
                return sanitizeFilename(ext[second + 1 ..]);
            }
        }
        return sanitizeFilename(ext);
    }
    if (disposition.param("filename")) |name| {
        return sanitizeFilename(name);
    }
    return null;
}

// Strips any directory components, guarding against path traversal. Content-
// Disposition can carry Windows separators, so backslashes are stripped too,
// regardless of the host platform.
fn sanitizeFilename(name: []const u8) ?[]const u8 {
    var out = std.fs.path.basename(name);
    if (std.mem.lastIndexOfScalar(u8, out, '\\')) |i| {
        out = out[i + 1 ..];
    }
    if (out.len == 0 or std.mem.eql(u8, out, ".") or std.mem.eql(u8, out, "..")) {
        return null;
    }
    return out;
}

// Derives a filename from a URL's last path segment. The path is taken from a
// real URL parse (rust-url) so query/fragment and percent-encoding are handled
// the same way the rest of the browser handles URLs. The result is duped into
// `arena`, since the parsed URL is freed before this returns.
fn urlBasename(arena: Allocator, url: []const u8) !?[]const u8 {
    var err: i32 = 0;
    const u = sys_url.url_parse(url.ptr, url.len, &err) orelse return null;
    defer sys_url.url_free(u);

    var ptr: [*]const u8 = undefined;
    var len: usize = undefined;
    sys_url.url_get_path(u, &ptr, &len);

    const name = sanitizeFilename(ptr[0..len]) orelse return null;
    return try arena.dupe(u8, name);
}

fn frameDataCallback(response: HttpClient.Response, data: []const u8) !void {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

    if (self._parse_state == .pre) {
        // we lazily do this, because we might need the first chunk of data
        // to sniff the content type
        var mime: Mime = blk: {
            if (response.contentType()) |ct| {
                break :blk try Mime.parse(ct);
            }
            break :blk Mime.sniff(data);
        } orelse .unknown;

        // If the HTTP Content-Type header didn't specify a charset and this is HTML,
        // prescan the first 1024 bytes for a <meta charset> declaration.
        if (mime.content_type == .text_html and mime.is_default_charset) {
            if (Mime.prescanCharset(data)) |charset| {
                if (charset.len <= 40) {
                    @memcpy(mime.charset[0..charset.len], charset);
                    mime.charset[charset.len] = 0;
                    mime.charset_len = charset.len;
                }
            }
        }

        if (comptime IS_DEBUG) {
            log.debug(.frame, "navigate first chunk", .{
                .content_type = mime.content_type,
                .len = data.len,
                .type = self._type,
                .url = self.url,
            });
        }

        switch (mime.content_type) {
            .text_html => {
                // Normalize and store the charset using encoding_rs canonical names
                const charset_str = mime.charsetString();
                const info = h5e.encoding_for_label(charset_str.ptr, charset_str.len);
                if (info.isValid()) {
                    self.charset = info.name();
                }
                self._parse_state = .{ .html = .{
                    .buffer = .empty,
                    .arena = try self.getArena(.large, "Frame.navigate"),
                } };
            },
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
        .html => |*html| try html.buffer.appendSlice(html.arena, data),
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
        .download => |*download| {
            download.file.writeAll(data) catch |err| {
                // TODO(#2701 follow-up): surface the write failure properly. We
                // can't set `_parse_state = .err` here because the next chunk
                // would then hit the `.err => unreachable` branch below, and we
                // should also emit a `canceled` downloadProgress and remove the
                // partial file on disk. For now we just log and keep going.
                log.err(.frame, "download write", .{ .err = err, .guid = download.guid });
                return;
            };
            download.received += data.len;
        },
        .pre => unreachable,
        .complete => unreachable,
        .err => unreachable,
        .raw_done => unreachable,
    }
}

fn frameDoneCallback(ctx: *anyopaque) !void {
    var self: *Frame = @ptrCast(@alignCast(ctx));

    if (comptime IS_DEBUG) {
        log.debug(.frame, "navigate done", .{ .type = self._type, .url = self.url });
    }

    //We need to handle different navigation types differently.
    try self._session.navigation.commitNavigation(self);

    defer if (comptime IS_DEBUG) {
        log.debug(.frame, "frame load complete", .{
            .url = self.url,
            .type = self._type,
            .state = std.meta.activeTag(self._parse_state),
        });
    };

    const parse_arena = try self.getArena(.medium, "Frame.parse");
    defer self.releaseArena(parse_arena);

    var parser = Parser.init(parse_arena, self.document.asNode(), self, .{ .allow_declarative_shadow = true });

    switch (self._parse_state) {
        .html => |*html| {
            {
                defer {
                    self.releaseArena(html.arena);
                    self._parse_state = .complete;
                }

                const raw_html = html.buffer.items;

                if (std.mem.eql(u8, self.charset, "UTF-8")) {
                    parser.parse(raw_html);
                } else {
                    parser.parseWithEncoding(raw_html, self.charset);
                }
            }
            self._script_manager.staticScriptsDone();
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
                "\"></body></html>",
            });
            parser.parse(html);
            self.documentIsComplete();
        },
        .raw => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        .pre => {
            // Received a response without a body like: https://httpbin.io/status/200
            // We assume we have received an OK status (checked in Client.headerCallback)
            // so we load a blank document to navigate away from any prior frame.
            self._parse_state = .{ .complete = {} };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        .err => |err| {
            // Generate a pseudo HTML page indicating the failure.
            const html = try std.mem.concat(parse_arena, u8, &.{
                "<html><head><meta charset=\"utf-8\"></head><body><h1>Navigation failed</h1><p>Reason: ",
                @errorName(err),
                "</p></body></html>",
            });

            parser.parse(html);
            self._parse_state = .complete;
            self.documentIsComplete();
        },
        .download => |*download| {
            download.file.close();

            // Capture before invalidating the union below.
            const guid = download.guid;
            const received = download.received;
            const total = download.total orelse download.received;
            self._parse_state = .complete;

            const session = self._session;
            if (session.download_events_enabled) {
                session.notification.dispatch(.download_progress, &.{
                    .guid = guid,
                    .total_bytes = total,
                    .received_bytes = received,
                    .state = .completed,
                });
            }

            // The body went to disk; commit an empty document so the frame
            // navigation still completes cleanly (mirrors the .raw path).
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        else => unreachable,
    }
}

fn frameErrorCallback(ctx: *anyopaque, err: anyerror) void {
    var self: *Frame = @ptrCast(@alignCast(ctx));

    self._last_navigate_error = err;
    log.err(.frame, "navigate failed", .{ .err = err, .type = self._type, .url = self.url });

    // A navigation that fails before any response headers arrive never
    // reaches the frame_navigated dispatch in frameHeaderCallback, so the
    // Page.navigate command that initiated it would stay unanswered forever.
    // Tell CDP so it can answer with an errorText (Chrome semantics).
    // _http_status is set as soon as headers are processed; non-null means
    // frameHeaderCallback already answered the command — don't answer twice.
    if (self._http_status == null) {
        self._session.notification.dispatch(.frame_navigate_failed, &.{
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .timestamp = timestamp(.monotonic),
            .url = self.url,
            .err = err,
            .opts = self._navigated_options orelse .{},
        });
    }

    // A pending root navigation that failed before commit: discard the
    // pending Page; the OLD active Page (and its V8 context) is untouched.
    // We do NOT run frameDoneCallback against the pending frame — the frame
    // is about to be freed.
    if (self._page.replaces != null) {
        self._session.discardPendingPage(self._page);
        return;
    }

    self._parse_state.deinit(self);
    self._parse_state = .{ .err = err };

    // In case of error, we want to complete the frame with a custom HTML
    // containing the error.
    frameDoneCallback(ctx) catch |e| {
        log.err(.browser, "frameErrorCallback", .{ .err = e, .type = self._type, .url = self.url });
        return;
    };
}
pub fn isGoingAway(self: *const Frame) bool {
    if (self._queued_navigation != null) {
        return true;
    }
    const parent = self.parent orelse return false;
    return parent.isGoingAway();
}

pub fn scriptAddedCallback(self: *Frame, comptime from_parser: bool, script: *Element.Html.Script) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another frame, don't run this script
        return;
    }

    if (comptime from_parser) {
        // parser-inserted scripts have force-async set to false, but only if
        // they have src or non-empty content
        if (script._src.len > 0 or script.asNode().firstChild() != null) {
            script._force_async = false;
        }
    }

    self._script_manager.addFromElement(from_parser, script, "parsing") catch |err| {
        log.err(.frame, "frame.scriptAddedCallback", .{
            .err = err,
            .url = self.url,
            .src = script.asElement().getAttributeSafe(comptime .wrap("src")),
            .type = self._type,
        });
    };
}

pub fn iframeAddedCallback(self: *Frame, iframe: *IFrame) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another frame, don't load this iframe
        return;
    }
    if (iframe._executed) {
        return;
    }
    if (!self._session.subframe_loading_enabled) {
        // configured not to load frames
        iframe._executed = true;
        return;
    }

    var src = iframe.asElement().getAttributeSafe(comptime .wrap("src")) orelse "";
    if (src.len == 0) {
        src = "about:blank";
    }

    if (iframe._window != null) {
        // This frame is being re-navigated. We need to do this through a
        // scheduleNavigation phase. We can't navigate immediately here, for
        // the same reason that a "root" frame can't immediately navigate:
        // we could be in the middle of a JS callback or something else that
        // doesn't exit the frame to just suddenly go away.
        return self.scheduleNavigation(src, .{
            .reason = .script,
            .kind = .{ .push = null },
        }, .{ .iframe = iframe });
    }

    iframe._executed = true;
    const session = self._session;

    const new_frame = try self.arena.create(Frame);
    const frame_id = session.nextFrameId();

    try Frame.init(new_frame, frame_id, self._page, .{ .parent = self });
    errdefer new_frame.deinit();

    self._pending_loads += 1;
    new_frame.iframe = iframe;
    iframe._window = new_frame.window;
    errdefer iframe._window = null;

    // on first load, dispatch frame_created event
    self._session.notification.dispatch(.frame_child_frame_created, &.{
        .parent_id = self._frame_id,
        .frame_id = new_frame._frame_id,
        .loader_id = new_frame._loader_id,
        .timestamp = timestamp(.monotonic),
    });

    const url = blk: {
        if (std.mem.eql(u8, src, "about:blank")) {
            break :blk "about:blank"; // navigate will handle this special case
        }
        break :blk try URL.resolve(
            self.call_arena, // ok to use, frame.navigate dupes this
            self.base(),
            src,
            .{ .encoding = self.charset },
        );
    };

    // Append the new frame before navigate() so synchronous navigation paths
    // (about:blank, blob:) and the notifications they dispatch can see this
    // frame in self.child_frames.
    try self.child_frames.append(self.arena, new_frame);

    // navigate() may run JS that reads window[N]; flag the list unsorted until
    // we've verified ordering post-navigate.
    const was_sorted = self.child_frames_sorted;
    self.child_frames_sorted = false;

    // Iframe's initial src request carries the parent's URL as Referer and
    // as the SameSite initiator. Parent frame outlives this navigate()
    // call, so the slice is safe.
    const parent_url: ?[:0]const u8 = if (std.mem.startsWith(u8, self.url, "http")) self.url else null;
    new_frame.navigate(url, .{
        .reason = .initialFrameNavigation,
        .referer = parent_url,
        .initiator_url = parent_url,
    }) catch |err| {
        // extra defensive..maybe navigate added a new frame, and the index it
        // was added at was removed. Or maybe this frame was removed somehow
        // (which I don't think is possible)
        if (std.mem.indexOfScalar(*Frame, self.child_frames.items, new_frame)) |idx| {
            _ = self.child_frames.swapRemove(idx);
        }
        log.warn(.frame, "iframe navigate failure", .{ .url = url, .err = err });
        self._pending_loads -= 1;
        iframe._window = null;
        return error.IFrameLoadError;
    };

    // window[N] is based on document order. We appended above and rely on
    // child_frames_sorted to tell window.getFrame whether it has to sort.
    // Since we expect frames to often be added in document order, do a quick
    // check to keep the list flagged as sorted when possible.
    const frames_len = self.child_frames.items.len;
    if (frames_len == 1) {
        // this is the only frame, it must be sorted.
        self.child_frames_sorted = true;
        return;
    }

    if (!was_sorted) {
        // it was already unsorted; leave flag false
        return;
    }

    // So we added a frame into a sorted list. If this frame is sorted relative
    // to the last frame, it's still sorted
    const iframe_a = self.child_frames.items[frames_len - 2].iframe.?;
    const iframe_b = self.child_frames.items[frames_len - 1].iframe.?;

    if (iframe_a.asNode().compareDocumentPosition(iframe_b.asNode()) & 0x04 != 0) {
        // b follows a (& 0x04 == 0x04), so the appended frame is in document
        // order relative to the previous tail — the list is still sorted.
        self.child_frames_sorted = true;
    }
}

const OpenPopupOpts = struct {
    url: []const u8,
    name: []const u8,
    opener: ?*Window,
};

// Create a new top-level browsing context as a sibling of the root frame.
// The popup shares the Page's arena, factory, and identity map, but has no
// parent and is not attached to the frame tree — it lives in page.popups.
pub fn openPopup(self: *Frame, opts: OpenPopupOpts) !*Frame {
    const page = self._page;
    const session = self._session;

    const resolved_url: [:0]const u8 = blk: {
        if (opts.url.len == 0) {
            break :blk "about:blank";
        }
        if (std.mem.eql(u8, opts.url, "about:blank")) {
            break :blk "about:blank";
        }
        const frame_base = base_blk: {
            var frame = self;
            while (true) {
                const maybe_base = frame.base();
                if (!std.mem.eql(u8, maybe_base, "about:blank")) {
                    break :base_blk maybe_base;
                }
                frame = frame.parent orelse break :base_blk "";
            }
        };
        break :blk try URL.resolve(self.call_arena, frame_base, opts.url, .{ .always_dupe = true, .encoding = self.charset });
    };

    const popup = try page.frame_arena.create(Frame);
    errdefer page.frame_arena.destroy(popup);

    const frame_id = session.nextFrameId();
    try Frame.init(popup, frame_id, page, .{});
    errdefer popup.deinit();

    popup.window._opener = opts.opener;
    if (opts.name.len > 0 and
        !std.ascii.eqlIgnoreCase(opts.name, "_blank") and
        !std.ascii.eqlIgnoreCase(opts.name, "_self") and
        !std.ascii.eqlIgnoreCase(opts.name, "_parent") and
        !std.ascii.eqlIgnoreCase(opts.name, "_top"))
    {
        popup.window._name = try page.frame_arena.dupe(u8, opts.name);
    }

    const popup_index = page.popups.items.len;
    try page.popups.append(page.frame_arena, popup);
    // not impossible that navigate adds popups, so remove by index
    errdefer _ = page.popups.swapRemove(popup_index);

    popup.navigate(resolved_url, .{ .reason = .script }) catch |err| {
        log.warn(.frame, "popup navigate failure", .{ .url = resolved_url, .err = err });
        return err;
    };

    return popup;
}

pub fn domChanged(self: *Frame) void {
    self._page.dom_version += 1;

    if (self._intersection.check_scheduled) {
        return;
    }

    self._intersection.check_scheduled = true;
    self.js.queueIntersectionChecks() catch |err| {
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

const ElementIdMaps = struct { lookup: *std.StringHashMapUnmanaged(*Element), removed_ids: *std.StringHashMapUnmanaged(void) };

fn getElementIdMap(frame: *Frame, node: *Node) ElementIdMaps {
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
                .lookup = &frame.document._elements_by_id,
                .removed_ids = &frame.document._removed_ids,
            };
        };

        current = parent;
    }
}

pub fn addElementId(self: *Frame, parent: *Node, element: *Element, id: []const u8) !void {
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

pub fn removeElementId(self: *Frame, element: *Element, id: []const u8) void {
    const node = element.asNode();
    self.removeElementIdWithMaps(self.getElementIdMap(node), id);
}

pub fn removeElementIdWithMaps(self: *Frame, id_maps: ElementIdMaps, id: []const u8) void {
    if (id_maps.lookup.remove(id)) {
        const owned_id = self.dupeString(id) catch return;
        id_maps.removed_ids.put(self.arena, owned_id, {}) catch |err| {
            log.warn(.frame, "removeElementIdWithMaps", .{ .err = err });
        };
    }
}

pub fn getElementByIdFromNode(self: *Frame, node: *Node, id: []const u8) ?*Element {
    // The id map lives on the node's root: a Document, or a ShadowRoot for
    // shadow DOM. Walk to the root once and consult the matching map.
    const root = node.getRootNode(.{});
    if (root._type == .document) {
        return root._type.document.getElementById(id, self);
    }
    if (root.is(ShadowRoot)) |shadow_root| {
        return shadow_root.getElementById(id, self);
    }
    // Detached subtree (root is neither a Document nor a ShadowRoot): no id map
    // exists, so scan it.
    var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(node, .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub fn performance(self: *Frame) *Performance {
    return &self.window._performance;
}

// Tracks a file input's FileList so its File refs are released at teardown.
pub fn trackFileList(self: *Frame, file_list: *FileList) !void {
    try self._file_lists.append(self.arena, file_list);
}

pub const QueuedEvent = struct {
    kind: Kind,
    element: *Element.Html,

    pub const Kind = enum { load, @"error" };
};

pub fn queueLoad(self: *Frame, html: *Element.Html) !void {
    try self.queueElementEvent(html, .load);
}

pub fn queueElementEvent(self: *Frame, element: *Element.Html, kind: QueuedEvent.Kind) !void {
    try self._queued_events.append(self.arena, .{ .element = element, .kind = kind });
    if (self._queued_events.items.len == 1) {
        try self.js.scheduler.add(self, struct {
            fn cleanup(ctx: *anyopaque) !?u32 {
                const f: *Frame = @ptrCast(@alignCast(ctx));
                try f.dispatchQueuedEvents();
                return null;
            }
        }.cleanup, 0, .{ .name = "frame.dispatchQueuedEvents" });
    }
}

const HashChangeCallback = struct {
    frame: *Frame,
    old_url: []const u8,
    new_url: []const u8,

    // Called by the scheduler if the task is dropped before it runs (e.g. the
    // page is torn down).
    fn cancelled(ctx: *anyopaque) void {
        const self: *HashChangeCallback = @ptrCast(@alignCast(ctx));
        self.frame._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *HashChangeCallback = @ptrCast(@alignCast(ctx));
        defer self.frame._factory.destroy(self);

        const frame = self.frame;
        const target = frame.window.asEventTarget();
        if (!frame._event_manager.hasDirectListeners(target, "hashchange", frame.window._on_hashchange)) {
            return null;
        }

        const event = (try HashChangeEvent.initTrusted(comptime .wrap("hashchange"), .{
            .oldURL = self.old_url,
            .newURL = self.new_url,
        }, frame)).asEvent();
        try frame._event_manager.dispatchDirect(target, event, frame.window._on_hashchange, .{ .context = "Hash Change" });
        return null;
    }
};

pub fn queueHashChange(self: *Frame, old_url: []const u8, new_url: []const u8) !void {
    const callback = try self._factory.create(HashChangeCallback{
        .frame = self,
        .old_url = old_url,
        .new_url = new_url,
    });
    try self.js.scheduler.add(callback, HashChangeCallback.run, 0, .{
        .name = "frame.hashChange",
        .finalizer = HashChangeCallback.cancelled,
    });
}

// Hard cap on a single external stylesheet body. CSS rule storage is per-
// arena so a hostile sheet could otherwise inflate page memory; 2 MiB is
// well above anything seen on real sites (Tailwind's `preflight + utilities`
// build is ~400 KiB gzipped, ~3 MiB raw — at which point a site should be
// splitting by route anyway).
const MAX_STYLESHEET_BYTES: usize = 2 * 1024 * 1024;

// start prefetching <link rel="preload" as="script" href=...>`
pub fn preloadScriptHint(self: *Frame, element: *Element.Html, href: []const u8) bool {
    if (self.isGoingAway() or self._parse_mode == .fragment) {
        return false;
    }

    const arena = self.getArena(.small, "Frame.preloadScriptHint") catch return false;
    defer self.releaseArena(arena);

    const resolved = URL.resolve(arena, self.base(), href, .{ .encoding = self.charset }) catch return false;
    if (!std.ascii.startsWithIgnoreCase(resolved, "http:") and !std.ascii.startsWithIgnoreCase(resolved, "https:")) {
        // data:/blob: are synthesized locally — no round-trip to hide.
        return false;
    }
    return self._script_manager.preloadScript(element, resolved) catch false;
}

// start prefetching <link rel="modulepreload" href=...>
pub fn preloadModuleHint(self: *Frame, element: *Element.Html, href: []const u8) bool {
    if (self.isGoingAway() or self._parse_mode == .fragment) {
        return false;
    }

    // The url becomes the imported_modules key, which must outlive the fetch
    // so it lives on the frame arena
    const resolved = URL.resolve(self.arena, self.base(), href, .{ .encoding = self.charset }) catch return false;
    if (!std.ascii.startsWithIgnoreCase(resolved, "http:") and !std.ascii.startsWithIgnoreCase(resolved, "https:")) {
        // data:/blob: are synthesized locally — no round-trip to hide.
        return false;
    }

    return self._script_manager.base.preloadModuleHint(element, resolved, self.url) catch false;
}

// Synchronously fetch and parse an external `<link rel=stylesheet>`.
// href is passed in as an optimization since the [currently] only callsite has
// it, so why look it up again?
pub fn loadExternalStylesheet(self: *Frame, link: *Element.Html.Link, href: []const u8) !void {
    if (self.isGoingAway() or href.len == 0) {
        return;
    }

    const session = self._session;

    // this feature is disabled by default, and can be turned on via a command
    // line flag or via an CDP command
    if (session.load_external_stylesheets == false) {
        return self.queueLoad(link._proto);
    }

    // Fragment-parsed links (innerHTML, DOMParser, ...) may not be attached.
    // TODO: this isn't correct in all cases. If the link is added into an
    // attached node, I think we SHOULD load it.
    if (self._parse_mode == .fragment) {
        return;
    }
    const element = link.asElement();

    const arena = try session.getArena(.medium, "Frame.loadExternalStylesheet");
    defer session.releaseArena(arena);

    const resolved = URL.resolve(arena, self.base(), href, .{ .encoding = self.charset }) catch |err| {
        log.warn(.http, "external stylesheet resolve", .{ .err = err, .href = href });
        try self.fireElementEvent(element, comptime .wrap("error"));
        return;
    };

    const http_client = &session.browser.http_client;
    var headers = try http_client.newHeaders();
    try headers.add("Accept: text/css,*/*;q=0.1");
    try self.headersForRequest(&headers);

    // Set the script-manager `is_evaluating` flag for the same reason
    // `ScriptManager.addFromElement` does: `syncRequest` pumps the CDP
    // socket inline, so a `Target.closeTarget` / `Page.close` arriving
    // mid-fetch would otherwise drive `Session.removePage` while this
    // function still holds pointers to `self`. The check in
    // `Session.removePage` (Session.zig:253) consults
    // `frame.anyScriptEvaluating()`, which only sees this flag.
    const sm = &self._script_manager.base;
    const was_evaluating = sm.is_evaluating;
    sm.is_evaluating = true;
    defer sm.endEvaluationWindow(was_evaluating);

    var response = http_client.syncRequest(arena, .{
        .url = resolved,
        .method = .GET,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .headers = headers,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = self.url,
        .resource_type = .stylesheet,
        .notification = session.notification,
    }) catch |err| {
        log.warn(.http, "external stylesheet fetch", .{ .err = err, .url = resolved });
        return self.fireElementEvent(element, comptime .wrap("error"));
    };
    defer response.deinit(arena);

    if (response.status < 200 or response.status >= 300) {
        log.info(.http, "external stylesheet status", .{ .status = response.status, .url = resolved });
        return self.fireElementEvent(element, comptime .wrap("error"));
    }

    if (response.body.items.len > MAX_STYLESHEET_BYTES) {
        log.warn(.http, "external stylesheet too large", .{
            .bytes = response.body.items.len,
            .max = MAX_STYLESHEET_BYTES,
            .url = resolved,
        });
        return self.fireElementEvent(element, comptime .wrap("error"));
    }

    // Reuse the cached sheet on re-fetch (href mutation on a connected
    // link) so `document.styleSheets` keeps a single entry per <link>
    // instead of accumulating one per href change. On first load, create
    // and register; on subsequent loads, replace content in place.
    //
    // First-load creation assigns `link._sheet` AFTER `sheets.add`
    // succeeds so an OOM during registration doesn't cache an unregistered
    // sheet (which would short-circuit every future re-fetch via the
    // `orelse` branch, leaving the sheet permanently unreachable through
    // `document.styleSheets`).
    const sheet = link._sheet orelse blk: {
        const new_sheet = try CSSStyleSheet.initWithOwner(element, self);
        const sheets = try self.document.getStyleSheets(self);
        try sheets.add(new_sheet, self);
        link._sheet = new_sheet;
        break :blk new_sheet;
    };

    // Parse first, only swap `_href` on success. `replaceSync` itself is
    // not atomic (clears rules before the insert loop), so a mid-parse
    // OOM still drops the old rules — full atomicity would require a
    // scratch-list pattern in `CSSStyleSheet.replaceSync`. Keeping
    // `_href` consistent with what the sheet actually contains is the
    // minimum.
    sheet.replaceSync(response.body.items, self) catch |err| {
        log.warn(.http, "external stylesheet parse", .{ .err = err, .url = resolved });
        return self.fireElementEvent(element, comptime .wrap("error"));
    };
    sheet._href = try self.arena.dupe(u8, resolved);

    try self.fireElementEvent(element, comptime .wrap("load"));
}

fn fireElementEvent(self: *Frame, el: *Element, name: String) !void {
    const event = try Event.initTrusted(name, .{}, self._page);
    try self._event_manager.dispatch(el.asEventTarget(), event);
}

fn dispatchQueuedEvents(self: *Frame) !void {
    const has_dom_load_listener = self._event_manager.has_dom_load_listener;

    // Swap buffers - new additions during dispatch go to the other buffer
    const to_process = self._queued_events;
    self._queued_events = if (self._queued_events == &self._queued_events_1)
        &self._queued_events_2
    else
        &self._queued_events_1;

    for (to_process.items) |queued| {
        const html_element = queued.element;
        const element = html_element.asElement();
        switch (queued.kind) {
            // hasAttributeFunction only sees handlers compiled via property
            // access; a parsed `onload="..."` attribute is compiled lazily at
            // dispatch (EventManager.getInlineHandler), so check it raw too.
            .load => {
                if (has_dom_load_listener or
                    html_element.hasAttributeFunction(.onload, self) or
                    element.getAttributeSafe(comptime .wrap("onload")) != null)
                {
                    try self.fireElementEvent(element, comptime .wrap("load"));
                }
            },
            .@"error" => {
                // errors are rare; not worth a listener-presence check
                try self.fireElementEvent(element, comptime .wrap("error"));
            },
        }
    }

    to_process.clearRetainingCapacity();
}

pub fn scheduleCustomElementBackupDrain(self: *Frame) !void {
    try self.js.queueCustomElementBackupDrain();
}

pub fn notifyNetworkIdle(self: *Frame) void {
    lp.assert(self._notified_network_idle == .done, "Frame.notifyNetworkIdle", .{});
    self._session.notification.dispatch(.frame_network_idle, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

pub fn notifyNetworkAlmostIdle(self: *Frame) void {
    lp.assert(self._notified_network_almost_idle == .done, "Frame.notifyNetworkAlmostIdle", .{});
    self._session.notification.dispatch(.frame_network_almost_idle, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

// called from the parser. Text-node merging is the parser's responsibility
// (see Parser.appendTextChunk in src/browser/parser/Parser.zig); this is the
// "insert this fully-formed node as a new last child of parent" entry point.
pub fn appendNew(self: *Frame, parent: *Node, child: *Node) !void {
    lp.assert(child._parent == null, "Frame.appendNew", .{});
    try self._insertNodeRelative(true, parent, child, .append, .{
        // this opts has no meaning since we're passing `true` as the first
        // parameter, which indicates this comes from the parser, and has its
        // own special processing. Still, set it to be clear.
        .child_already_connected = false,
    });
}

// called from the parser when the node and all its children have been added
pub fn nodeComplete(self: *Frame, node: *Node) !void {
    Node.Build.call(node, "complete", .{ node, self }) catch |err| {
        log.err(.bug, "build.complete", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
        return err;
    };
    return self.nodeIsReady(true, node);
}

// Sets the owner document for a node. Only stores entries for nodes whose owner
// is NOT frame.document to minimize memory overhead.
pub fn setNodeOwnerDocument(self: *Frame, node: *Node, owner: *Document) !void {
    if (owner == self.document) {
        // No need to store if it's the main document - remove if present
        _ = self._node_owner_documents.remove(node);
    } else {
        try self._node_owner_documents.put(self.arena, node, owner);
    }
}

// Recursively sets the owner document for a node and all its descendants
pub fn adoptNodeTree(self: *Frame, node: *Node, old_owner: *Document, new_owner: *Document) !void {
    try self.setNodeOwnerDocument(node, new_owner);

    // Per spec, adopted steps run on each element after its document is set.
    if (node.is(Element)) |el| {
        Element.Html.Custom.enqueueAdoptedCallbackOnElement(el, old_owner, new_owner, self);
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        try self.adoptNodeTree(child, old_owner, new_owner);
    }
}

pub fn dupeString(self: *Frame, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

// Direct (non-propagating) dispatch of an event. Mirrors WorkerGlobalScope.dispatch
// so worker-compatible APIs can uniformly call `global.dispatch(...)` across both
// Frame and Worker contexts.
pub fn dispatch(
    self: *Frame,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManager.DispatchDirectOptions,
) !void {
    return self._event_manager.dispatchDirect(target, event, handler, opts);
}

pub fn hasDirectListeners(self: *Frame, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

pub fn dupeSSO(self: *Frame, value: []const u8) !String {
    return String.init(self.arena, value, .{ .dupe = true });
}

const RemoveNodeOpts = struct {
    will_be_reconnected: bool,
};
pub fn removeNode(self: *Frame, parent: *Node, child: *Node, opts: RemoveNodeOpts) void {
    // Capture siblings before removing
    const previous_sibling = child.previousSibling();
    const next_sibling = child.nextSibling();

    // Capture child's index before removal for live range updates (DOM spec remove steps 4-7)
    const child_index_for_ranges: ?u32 = if (self._live_ranges.first != null)
        parent.getChildIndex(child)
    else
        null;

    const children = parent._children.?;
    children.remove(&child._child_link);
    if (children.first == null) {
        // last child removed; drop the list so a childless node holds no allocation
        parent._children = null;
        self._factory.destroy(children);
    }
    // grab this before we null the parent
    const was_connected = child.isConnected();
    // Capture the ID map before disconnecting, so we can remove IDs from the correct document
    const id_maps = if (was_connected) self.getElementIdMap(child) else null;

    child._parent = null;
    child._child_link = .{};

    // Update live ranges for removal (DOM spec remove steps 4-7)
    if (child_index_for_ranges) |idx| {
        self.updateRangesForNodeRemoval(parent, child, idx);
    }

    slotting.removalSteps(parent, child, self);

    if (observers.hasMutationObservers(self)) {
        const removed = [_]*Node{child};
        observers.notifyChildListChange(self, parent, &.{}, &removed, previous_sibling, next_sibling);
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

        Element.Html.Custom.enqueueDisconnectedCallbackOnElement(el, self);

        popover.removeFromOpen(el, self);

        // If a <style> element is being removed, remove its sheet from the list
        if (el.is(Element.Html.Style)) |style| {
            if (style._sheet) |sheet| {
                if (self.document._style_sheets) |sheets| {
                    sheets.remove(sheet);
                }
                style._sheet = null;
            }
            self._style_manager.sheetModified();
        } else if (el.is(Element.Html.Link)) |link| {
            // External stylesheet links registered via Frame.loadExternalStylesheet
            // must be symmetrically deregistered on disconnect, or
            // `document.styleSheets` accumulates phantom entries and the
            // visibility cascade keeps honoring rules from removed links —
            // exactly the SPA theme-switch pattern (append new sheet,
            // remove old) the feature exists to serve.
            if (link._sheet) |sheet| {
                if (self.document._style_sheets) |sheets| {
                    sheets.remove(sheet);
                }
                link._sheet = null;
                self._style_manager.sheetModified();
            }
        }
    }
}

pub fn appendNode(self: *Frame, parent: *Node, child: *Node, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, .append, opts);
}

pub fn appendAllChildren(self: *Frame, parent: *Node, target: *Node) !void {
    self.domChanged();
    const dest_connected = target.isConnected();

    var it = parent.childrenIterator();
    while (it.next()) |child| {
        const child_was_connected = child.isConnected();
        self.removeNode(parent, child, .{ .will_be_reconnected = dest_connected });
        try self.appendNode(target, child, .{ .child_already_connected = child_was_connected });
    }
}

pub fn insertAllChildrenBefore(self: *Frame, fragment: *Node, parent: *Node, ref_node: *Node) !void {
    self.domChanged();
    const dest_connected = parent.isConnected();

    var it = fragment.childrenIterator();
    while (it.next()) |child| {
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
pub fn insertNodeRelative(self: *Frame, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, relative, opts);
}
pub fn _insertNodeRelative(self: *Frame, comptime from_parser: bool, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    // caller should have made sure this was the case

    lp.assert(child._parent == null, "Frame.insertNodeRelative parent", .{});

    const children = parent._children orelse blk: {
        const list = try self._factory.create(std.DoublyLinkedList{});
        parent._children = list;
        break :blk list;
    };

    switch (relative) {
        .append => children.append(&child._child_link),
        .after => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Frame.insertNodeRelative after", .{ .url = self.url });
            children.insertAfter(&ref_node._child_link, &child._child_link);
        },
        .before => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Frame.insertNodeRelative before", .{ .url = self.url });
            children.insertBefore(&ref_node._child_link, &child._child_link);
        },
    }
    child._parent = parent;

    // Update live ranges for insertion (DOM spec insert step 6).
    // For .before/.after the child was inserted at a specific position;
    // ranges on parent with offsets past that position must be incremented.
    // For .append no range update is needed (spec: "if child is non-null").
    if (self._live_ranges.first != null) {
        switch (relative) {
            .append => {},
            .before, .after => {
                if (parent.getChildIndex(child)) |idx| {
                    self.updateRangesForNodeInsertion(parent, idx);
                }
            },
        }
    }

    if (self._element_shadow_roots.count() != 0) {
        // html5ever wraps fragment parses in a temporary <html> element that
        // gets unwrapped later; it must not take part in slot assignment.
        const in_fragment_parse = from_parser and self._parse_mode == .fragment;
        const is_fragment_wrapper = in_fragment_parse and child.is(Element.Html.Html) != null;
        if (is_fragment_wrapper == false) {
            slotting.insertionSteps(parent, child, in_fragment_parse, self);
        }
    }

    const parent_is_connected = parent.isConnected();

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
            // nodeComplete() callback is executed. nodeIsReady resolves the
            // node's owning frame itself (only for the few node types that have
            // ready work), so pass the incumbent `self`.
            try self.nodeIsReady(false, child);

            // Check if text was added to a script that hasn't started yet.
            if (child._type == .cdata and parent_is_connected) {
                if (parent.is(Element.Html.Script)) |script| {
                    if (!script._executed) {
                        try self.nodeIsReady(false, parent);
                    }
                }
            }
        }

        // Notify mutation observers about childList change
        if (observers.hasMutationObservers(self)) {
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            observers.notifyChildListChange(self, parent, &added, &.{}, previous_sibling, next_sibling);
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
                try Element.Html.Custom.enqueueConnectedCallbackOnElement(true, el, self);
            }
        }
        return;
    }

    if (opts.child_already_connected and !opts.adopting_to_new_document) {
        // The child is already connected in the same document, we don't have to reconnect it.
        // On cross-document adoption the child has already fired
        // disconnectedCallback against the old tree and must re-fire
        // connectedCallback for the new tree, so we fall through.
        return;
    }

    const parent_in_shadow = parent.is(ShadowRoot) != null or parent.isInShadowTree();

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
    // Cross-document adoption also counts as a transition: the element fired
    // disconnectedCallback against the old tree during removeNode and must
    // now fire connectedCallback against the new tree.
    const should_invoke_connected = parent_is_connected and (!opts.child_already_connected or opts.adopting_to_new_document);

    var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(child, .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            try self.addElementId(el.asNode()._parent.?, el, id);
        }

        if (should_invoke_connected) {
            try Element.Html.Custom.enqueueConnectedCallbackOnElement(false, el, self);
        }
    }
}

pub fn attributeChange(self: *Frame, element: *Element, name: String, value: String, old_value: ?String) void {
    _ = Element.Build.call(element, "attributeChange", .{ element, name, value, self }) catch |err| {
        log.err(.bug, "build.attributeChange", .{ .tag = element.getTag(), .name = name, .value = value, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.enqueueAttributeChangedCallbackOnElement(element, name, old_value, value, null, self);

    observers.notifyAttributeChange(self, element, name, old_value);

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        const old = if (old_value) |o| o.str() else "";
        slotting.slotAttributeChanged(element.asNode(), old, value.str(), self);
    } else if (name.eql(comptime .wrap("name"))) {
        if (element.is(Element.Html.Slot)) |slot| {
            const old = if (old_value) |o| o.str() else "";
            slotting.nameAttributeChanged(slot, old, value.str(), self);
        }
    } else if (name.eql(comptime .wrap("popover"))) {
        const old = if (old_value) |o| o.str() else null;
        popover.attributeChanged(element, old, value.str(), self);
    }
}

pub fn attributeRemove(self: *Frame, element: *Element, name: String, old_value: String) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.enqueueAttributeChangedCallbackOnElement(element, name, old_value, null, null, self);

    observers.notifyAttributeChange(self, element, name, old_value);

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        slotting.slotAttributeChanged(element.asNode(), old_value.str(), "", self);
    } else if (name.eql(comptime .wrap("name"))) {
        if (element.is(Element.Html.Slot)) |slot| {
            slotting.nameAttributeChanged(slot, old_value.str(), "", self);
        }
    } else if (name.eql(comptime .wrap("popover"))) {
        popover.attributeChanged(element, old_value.str(), null, self);
    }
}

pub fn signalSlotChange(self: *Frame, slot: *Element.Html.Slot) void {
    self._slots_pending_slotchange.put(self.arena, slot, {}) catch |err| {
        log.err(.frame, "signalSlotChange.put", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };
    observers.scheduleMutationDelivery(self) catch |err| {
        log.err(.frame, "signalSlotChange.schedule", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn getCustomizedBuiltInDefinition(self: *Frame, element: *Element) ?*CustomElementDefinition {
    return self._customized_builtin_definitions.get(element);
}

pub fn setCustomizedBuiltInDefinition(self: *Frame, element: *Element, definition: *CustomElementDefinition) !void {
    try self._customized_builtin_definitions.put(self.arena, element, definition);
}

// --- Live range update methods (DOM spec §4.2.3, §4.2.4, §4.7, §4.8) ---

/// Update all live ranges after a replaceData mutation on a CharacterData node.
/// Per DOM spec: insertData = replaceData(offset, 0, data),
///               deleteData = replaceData(offset, count, "").
/// All parameters are in UTF-16 code unit offsets.
pub fn updateRangesForCharacterDataReplace(self: *Frame, target: *Node, offset: u32, count: u32, data_len: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForCharacterDataReplace(target, offset, count, data_len);
    }
}

/// Update all live ranges after a splitText operation.
/// Steps 7b-7e of the DOM spec splitText algorithm.
/// Steps 7d-7e complement (not overlap) updateRangesForNodeInsertion:
/// the insert update handles offsets > child_index, while 7d/7e handle
/// offsets == node_index+1 (these are equal values but with > vs == checks).
pub fn updateRangesForSplitText(self: *Frame, target: *Node, new_node: *Node, offset: u32, parent: *Node, node_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForSplitText(target, new_node, offset, parent, node_index);
    }
}

/// Update all live ranges after a node insertion.
/// Per DOM spec insert algorithm step 6: only applies when inserting before a
/// non-null reference node.
pub fn updateRangesForNodeInsertion(self: *Frame, parent: *Node, child_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForNodeInsertion(parent, child_index);
    }
}

/// Update all live ranges after a node removal.
/// Per DOM spec remove algorithm steps 4-7.
pub fn updateRangesForNodeRemoval(self: *Frame, parent: *Node, child: *Node, child_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForNodeRemoval(parent, child, child_index);
    }
}

// TODO: optimize and cleanup, this is called a lot (e.g., innerHTML = '')
pub fn parseHtmlAsChildren(self: *Frame, node: *Node, html: []const u8) !void {
    return self.parseHtmlAsChildrenInner(node, html, .{});
}

// setHTMLUnsafe variant: parse a fragment that may contain declarative shadow node
pub fn parseHtmlUnsafeAsChildren(self: *Frame, node: *Node, html: []const u8) !void {
    return self.parseHtmlAsChildrenInner(node, html, .{ .allow_declarative_shadow = true });
}

// Range.createContextualFragment variant: unlike innerHTML et al., its scripts
// are run when the fragment is inserted into a document.
pub fn parseContextualFragment(self: *Frame, node: *Node, html: []const u8) !void {
    return self.parseHtmlAsChildrenInner(node, html, .{ .scripts_runnable = true });
}

const FragmentParseOpts = struct {
    scripts_runnable: bool = false,
    allow_declarative_shadow: bool = false,
};

fn parseHtmlAsChildrenInner(self: *Frame, node: *Node, html: []const u8, opts: FragmentParseOpts) !void {
    const previous_parse_mode = self._parse_mode;
    self._parse_mode = .fragment;
    defer self._parse_mode = previous_parse_mode;

    // The html5ever wrapper-unwrap below rebinds children without going
    // through the insertion path, so recompute slot assignments for any
    // shadow tree this fragment landed in (idempotent; signals only on diff).
    defer if (self._element_shadow_roots.count() != 0) {
        const root = node.getRootNode(.{});
        if (root.is(ShadowRoot) != null) {
            slotting.assignSlottablesForTree(root, self);
        }
        if (node.is(Element)) |el| {
            if (self._element_shadow_roots.get(el)) |shadow_root| {
                slotting.assignSlottablesForTree(shadow_root.asNode(), self);
            }
        }
    };

    const previous_scripts_runnable = self._fragment_scripts_runnable;
    self._fragment_scripts_runnable = opts.scripts_runnable;
    defer self._fragment_scripts_runnable = previous_scripts_runnable;

    var parser = Parser.init(self.call_arena, node, self, .{ .allow_declarative_shadow = opts.allow_declarative_shadow });
    parser.parseFragment(html);

    // html5ever wraps fragment output in an <html> element; unwrap so its
    // children land directly on `node`. See https://github.com/servo/html5ever/issues/583.
    // Because of custom element callbacks, the structure might not be what
    // we expect, and nodes might be altogether removed. We deal with this in a
    // few different places, but always the same way: leave it as-is.
    const children = node._children orelse return;
    const first = Node.linkToNode(children.first.?);
    if (first.is(Element.Html.Html) == null) {
        return;
    }
    node._children = first._children;

    if (observers.hasMutationObservers(self)) {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
            // Notify mutation observers for each unwrapped child
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            observers.notifyChildListChange(self, node, &added, &.{}, previous_sibling, next_sibling);
        }
    } else {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
        }
    }
}

fn nodeIsReady(self: *Frame, comptime from_parser: bool, node: *Node) !void {
    if ((comptime from_parser) and self._parse_mode == .fragment) {
        if (self._fragment_scripts_runnable == false) {
            // We don't execute scripts added via innerHTML = '<script...'. Mark
            // them "already started" so they stay inert even after the parsed
            // nodes are inserted into a connected document.
            if (node.is(Element.Html.Script)) |script| {
                script._executed = true;
            }
        }
        return;
    }
    // A node's "ready" work (running a <script>, loading an <iframe> / <link> /
    // <style>) must happen in the frame that owns the node's document — not
    // necessarily `self`. When an async callback (e.g. a postMessage listener)
    // running in frame A appends a node to frame B's document, `self` is the
    // incumbent frame A, but the script's base URL and execution realm must come
    // from B (its node document). Resolving that owner frame is a parent-chain
    // walk, so we only do it once we've matched a node type that has ready work
    // (the common text/element insertion does nothing here). The parser inserts
    // into its own document, so from_parser always uses `self`.
    if (node.is(Element.Html.Script)) |script| {
        if ((comptime from_parser == false) and script._src.len == 0) {
            // Script was added via JavaScript without a src attribute.
            // Only skip if it has no inline content either — scripts with
            // textContent/text should still execute per spec.
            if (node.firstChild() == null) {
                return;
            }
        }

        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        frame.scriptAddedCallback(from_parser, script) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "script", .type = frame._type, .url = frame.url });
            return err;
        };
    } else if (node.is(IFrame)) |iframe| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        frame.iframeAddedCallback(iframe) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "iframe", .type = frame._type, .url = frame.url });
            return err;
        };
    } else if (node.is(Element.Html.Link)) |link| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        link.linkAddedCallback(frame) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "link", .type = frame._type });
            return error.LinkLoadError;
        };
    } else if (node.is(Element.Html.Style)) |style| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        style.styleAddedCallback(frame) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "style", .type = frame._type });
            return error.StyleLoadError;
        };
    }
}

const ParseState = union(enum) {
    pre,
    complete,
    err: anyerror,
    html: struct {
        arena: Allocator,
        buffer: std.ArrayList(u8),
    },
    text: std.ArrayList(u8),
    image: std.ArrayList(u8),
    raw: std.ArrayList(u8),
    raw_done: []const u8,
    download: Download,

    fn deinit(self: *ParseState, frame: *Frame) void {
        switch (self.*) {
            .html => |html| frame.releaseArena(html.arena),
            // Only reached when a frame is torn down mid-download (the normal
            // completion path in frameDoneCallback already closes the file and
            // transitions to .complete).
            .download => |*download| download.file.close(),
            else => {},
        }
    }
};

// An in-flight file download (Content-Disposition: attachment under an
// allow/allowAndName Browser.setDownloadBehavior). The response body is
// streamed straight to `file` rather than parsed as a page. See issue #2701.
const Download = struct {
    // uuidv4, arena-owned. Matches the guid reported in the CDP events.
    guid: []const u8,
    file: std.fs.File,
    // suggested filename surfaced to the client, arena-owned.
    filename: []const u8,
    received: u64,
    // from Content-Length, when the response advertised one.
    total: ?u64,
};

const LoadState = enum {
    // waiting for the main HTML
    waiting,

    // the main HTML is being parsed (or downloaded)
    parsing,

    // the main HTML has been parsed and the JavaScript (including deferred
    // scripts) have been loaded. Corresponds to the DOMContentLoaded event
    load,

    // the frame has been loaded and all async scripts (if any) are done
    // Corresponds to the load event
    complete,
};

const IdleNotification = union(enum) {
    // hasn't started yet.
    init,

    // timestamp where the state was first triggered. If the state stays
    // true (e.g. 0 network activity for NetworkIdle, or <= 2 for NetworkAlmostIdle)
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
    method: HttpClient.Method = .GET,
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
    // Set by scheduleNavigationWithArena from the originating frame's URL so
    // anchor click / form submit / location.href navigations carry a Referer.
    // null on CDP Page.navigate (address-bar) and Page.reload — matches Chrome.
    referer: ?[]const u8 = null,
    // The URL of the document that initiated this navigation, used as the
    // "site for cookies" when computing SameSite. Distinct from `referer`
    // because a Referrer-Policy can suppress the Referer header without
    // affecting SameSite (which always considers the real initiator).
    initiator_url: ?[:0]const u8 = null,
    force: bool = false,
    kind: NavigationKind = .{ .push = null },
};

pub const NavigatedOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: HttpClient.Method = .GET,
    // Retained on the frame's arena so Page.reload can replay the prior
    // navigation's HTTP method — matches Chrome's F5 behavior on POST pages.
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
};

const NavigationType = enum {
    form,
    script,
    anchor,
    iframe,
};

const Navigation = union(NavigationType) {
    form: *Frame,
    script: ?*Frame,
    anchor: *Frame,
    iframe: *IFrame,
};

pub const QueuedNavigation = struct {
    arena: Allocator,
    url: [:0]const u8,
    opts: NavigateOpts,
    is_about_blank: bool,
    navigation_type: NavigationType,
};

/// Resolves a target attribute value (e.g., "_self", "_parent", "_top", or frame name)
/// to the appropriateFrame to navigate.
/// Returns null if the target is "_blank" (which would open a new window/tab).
/// Note: Callers should handle empty target separately (for owner document resolution).
pub fn resolveTargetFrame(self: *Frame, target_name: []const u8) ?*Frame {
    if (std.ascii.eqlIgnoreCase(target_name, "_self")) {
        return self;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_blank")) {
        return null;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_parent")) {
        return self.parent orelse self;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_top")) {
        var frame = self;
        while (frame.parent) |f| {
            frame = f;
        }
        return frame;
    }

    // Named frame lookup: search current frame's descendants first, then from root
    // This follows the HTML spec's "implementation-defined" search order.
    if (findFrameByName(self, target_name)) |f| {
        return f;
    }

    // If not found in descendants, search from root (catches siblings and ancestors' descendants)
    var root = self;
    while (root.parent) |f| {
        root = f;
    }
    if (root != self) {
        if (findFrameByName(root, target_name)) |f| {
            return f;
        }
    }

    // If no frame found with that name, navigate in current frame
    // (this matches browser behavior - unknown targets act like _self)
    return self;
}

fn findFrameByName(frame: *Frame, name: []const u8) ?*Frame {
    for (frame.child_frames.items) |f| {
        if (f.iframe) |iframe| {
            const frame_name = iframe.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
            if (std.mem.eql(u8, frame_name, name)) {
                return f;
            }
        }
        // Recursively search child frames
        if (findFrameByName(f, name)) |found| {
            return found;
        }
    }
    return null;
}

const SubmitFormOpts = struct {
    fire_event: bool = true,
};
pub fn submitForm(self: *Frame, submitter_: ?*Element, form_: ?*Element.Html.Form, submit_opts: SubmitFormOpts) !void {
    const form = form_ orelse return;

    // see the `_constructing_entry_list` field documentation
    if (form._constructing_entry_list) {
        return;
    }

    if (submitter_) |submitter| {
        if (submitter.getAttributeSafe(comptime .wrap("disabled")) != null) {
            return;
        }
    }

    if (self.canScheduleNavigation(.form) == false) {
        return;
    }

    const form_element = form.asElement();

    const submit_button: ?*Element = blk: {
        const s = submitter_ orelse break :blk null;
        break :blk if (Element.Html.Form.isSubmitButton(s)) s else null;
    };

    const target_name_: ?[]const u8 = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formtarget"))) |ft| {
                break :blk ft;
            }
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("target"));
    };

    const target_frame = blk: {
        const target_name = target_name_ orelse {
            break :blk form_element.asNode().ownerFrame(self);
        };
        break :blk self.resolveTargetFrame(target_name) orelse {
            log.warn(.not_implemented, "target", .{ .type = self._type, .url = self.url, .target = target_name });
            return;
        };
    };

    if (submit_opts.fire_event) {
        // Prevent a submit on the form from firing while we're submit the form.
        // This is both spec-correct AND prevents infinite recursion.
        if (form._firing_submission_events) {
            return;
        }
        form._firing_submission_events = true;
        defer form._firing_submission_events = false;

        // Per the HTML "submit a form element" algorithm: unless the form (or the
        // submitter, via formnovalidate) is in the no-validate state, interactively
        // validate the form's constraints and abort submission if it fails.
        // checkValidity() fires the `invalid` events on the offending controls.
        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
        const skip_validation = form.getNoValidate() or blk: {
            const s = submit_button orelse break :blk false;
            if (s.is(Element.Html.Form.Input)) |input| break :blk input.getFormNoValidate();
            if (s.is(Element.Html.Form.Button)) |button| break :blk button.getFormNoValidate();
            break :blk false;
        };
        if (!skip_validation and !try form.checkValidity(self)) {
            return;
        }

        // Per HTML spec "submit a form element" algorithm: SubmitEvent.submitter
        // must be null when the submitter is the form itself, which is what
        // Form.requestSubmit() passes when called with no submitter argument.
        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
        const submitter_html: ?*HtmlElement = blk: {
            const s = submitter_ orelse break :blk null;
            if (s == form_element) break :blk null;
            break :blk s.is(HtmlElement);
        };
        const submit_event = (try SubmitEvent.initTrusted(comptime .wrap("submit"), .{ .bubbles = true, .cancelable = true, .submitter = submitter_html }, self)).asEvent();

        // so submit_event is still valid when we check _prevent_default
        submit_event.acquireRef();
        defer _ = submit_event.releaseRef(self._page);

        try self._event_manager.dispatch(form_element.asEventTarget(), submit_event);
        // If the submit event was prevented, don't submit the form
        if (submit_event._prevent_default) {
            return;
        }
    }

    const FormData = @import("webapi/net/FormData.zig");

    // The submitter can be an input box (if enter was entered on the box)
    // I don't think this is technically correct, but FormData handles it ok
    const form_data = try FormData.init(form, submitter_, &self.js.execution);
    form_data.acquireRef();
    defer form_data.releaseRef(self._page);

    const arena = try self._session.getArena(.medium, "submitForm");
    errdefer self._session.releaseArena(arena);

    // Per HTML spec form-submission algorithm, when the submitter is a submit
    // button, its formaction/formmethod/formenctype attributes override the
    // form's corresponding attributes (matching how formtarget is honored above).
    // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
    const enctype_attr = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formenctype"))) |fe| break :blk fe;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("enctype"));
    };
    const method_attr: ?[]const u8 = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formmethod"))) |fm| break :blk fm;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("method"));
    };
    const method = Element.Html.Form.normalizeMethod(method_attr, "get");
    const is_post = std.mem.eql(u8, method, "post");

    // Get charset from accept-charset attribute or fall back to document charset
    const charset: []const u8 = blk: {
        if (form_element.getAttributeSafe(.wrap("accept-charset"))) |ac| {
            // Normalize to canonical encoding name
            const info = h5e.encoding_for_label(ac.ptr, ac.len);
            if (info.isValid()) {
                break :blk info.name();
            }
        }
        break :blk self.charset;
    };

    var boundary_buf: [36]u8 = undefined;
    // GET ignores enctype per HTML spec; only resolve the union for POST.
    const encoding: FormData.EncType = blk: {
        if (!is_post) break :blk .urlencode;
        const canonical = Element.Html.Form.normalizeEnctype(enctype_attr, "application/x-www-form-urlencoded");
        if (std.mem.eql(u8, canonical, "multipart/form-data")) {
            @import("../id.zig").uuidv4(&boundary_buf);
            break :blk .{ .formdata = &boundary_buf };
        }
        if (std.mem.eql(u8, canonical, "text/plain")) {
            break :blk .plaintext;
        }
        break :blk .urlencode;
    };

    var buf = std.Io.Writer.Allocating.init(arena);
    try form_data.write(.{ .encoding = encoding, .charset = charset, .allocator = arena }, &buf.writer);

    var action = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formaction"))) |fa| break :blk fa;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("action")) orelse self.url;
    };

    var opts = NavigateOpts{
        .reason = .form,
        .kind = .{ .push = null },
    };
    if (is_post) {
        opts.method = .POST;
        opts.body = buf.written();
        opts.header = switch (encoding) {
            .urlencode => "Content-Type: application/x-www-form-urlencoded",
            .formdata => |b| try std.fmt.allocPrintSentinel(arena, "Content-Type: multipart/form-data; boundary={s}", .{b}, 0),
            // Per WHATWG HTML §4.10.21.6, text/plain submissions include the form's
            // resolved encoding (accept-charset or document charset).
            .plaintext => try std.fmt.allocPrintSentinel(arena, "Content-Type: text/plain; charset={s}", .{charset}, 0),
        };
    } else {
        action = try URL.concatQueryString(arena, action, buf.written());
    }

    return self.scheduleNavigationWithArena(arena, action, opts, .{ .form = target_frame });
}

const testing = @import("../testing.zig");

fn dispositionHeader(value: []const u8) HttpClient.Header {
    return .{ .name = "content-disposition", .value = value };
}

test "Frame: dispositionFilename" {
    try testing.expectEqualSlices(u8, "report.csv", dispositionFilename(dispositionHeader("attachment; filename=\"report.csv\"")).?);
    try testing.expectEqualSlices(u8, "report.csv", dispositionFilename(dispositionHeader("attachment; filename=report.csv")).?);
    try testing.expectEqualSlices(u8, "r e.csv", dispositionFilename(dispositionHeader("attachment; filename=\"r e.csv\"")).?);
    // RFC 5987 extended form is preferred over the plain filename when present
    // (the value is taken verbatim after the charset'lang' prefix).
    try testing.expectEqualSlices(u8, "extended.txt", dispositionFilename(dispositionHeader("attachment; filename=\"fallback.txt\"; filename*=UTF-8''extended.txt")).?);
    try testing.expect(dispositionFilename(dispositionHeader("attachment")) == null);
    // Path components are stripped to guard against traversal.
    try testing.expectEqualSlices(u8, "evil.sh", dispositionFilename(dispositionHeader("attachment; filename=\"../../evil.sh\"")).?);
    try testing.expectEqualSlices(u8, "evil.sh", dispositionFilename(dispositionHeader("attachment; filename=\"..\\..\\evil.sh\"")).?);
    try testing.expect(dispositionFilename(dispositionHeader("attachment; filename=\"..\"")) == null);
}

test "Frame: urlBasename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualSlices(u8, "report.csv", (try urlBasename(a, "http://x.com/a/b/report.csv")).?);
    try testing.expectEqualSlices(u8, "report.csv", (try urlBasename(a, "http://x.com/report.csv?v=1#x")).?);
    try testing.expect((try urlBasename(a, "http://x.com/")) == null);
}

test "WebApi: Frame" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("page", .{});
}

test "WebApi: Frames" {
    try testing.htmlRunner("frames", .{});
}

test "WebApi: Integration" {
    try testing.htmlRunner("integration", .{});
}

test "WebApi: inject_script" {
    try testing.htmlRunner("inject_script.html", .{
        .inject_script = "window.__injected = true; window.__injectValue = 42;",
    });
}

test "Page: isSameOrigin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var frame: Frame = undefined;

    frame.origin = null;
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com/"));

    frame.origin = try URL.getOrigin(allocator, "https://origin.com/foo/bar") orelse unreachable;
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo/bar")); // exact same
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/bar/bar")); // path differ
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/")); // path differ
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com")); // no path
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo?q=1"));
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo#hash"));
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo?q=1#hash"));
    // FIXME try testing.expectEqual(true, frame.isSameOrigin("https://foo:bar@origin.com"));
    // FIXME try testing.expectEqual(true, frame.isSameOrigin("https://origin.com:443/foo"));

    try testing.expectEqual(false, frame.isSameOrigin("http://origin.com/")); // another proto
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com:123/")); // another port
    try testing.expectEqual(false, frame.isSameOrigin("https://sub.origin.com/")); // another subdomain
    try testing.expectEqual(false, frame.isSameOrigin("https://target.com/")); // different domain
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com.target.com/")); // different domain
    try testing.expectEqual(false, frame.isSameOrigin("https://target.com/@origin.com"));

    frame.origin = try URL.getOrigin(allocator, "https://origin.com:8443/foo") orelse unreachable;
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com:8443/bar"));
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com/bar")); // missing port
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com:9999/bar")); // wrong port

    try testing.expectEqual(false, frame.isSameOrigin(""));
    try testing.expectEqual(false, frame.isSameOrigin("not-a-url"));
    try testing.expectEqual(false, frame.isSameOrigin("//origin.com/foo"));
}

test "Frame: httpMetadata after navigation" {
    const page = try testing.pageTest("page/meta.html", .{});
    defer page.close();

    const meta = page.frame().?.httpMetadata();
    try testing.expect(meta.status != null);
    try std.testing.expectEqual(@as(u16, 200), meta.status.?);
    try testing.expect(meta.headers.len > 0);
    try testing.expect(meta.url.len > 0);
}

test "Frame: httpMetadata 404" {
    const page = try testing.pageTest("nonexistent_page_xyz.html", .{});
    defer page.close();

    const meta = page.frame().?.httpMetadata();
    try testing.expect(meta.status != null);
    try testing.expectEqual(404, meta.status.?);
}

test "Frame: 401" {
    defer testing.reset();

    var page = try testing.pageTest("401", .{});
    defer page.close();

    const frame = page.frame().?;

    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try @import("dump.zig").root(frame.document, .{}, &buf.writer, frame);
    try testing.expectEqual("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><pre>No</pre></body></html>", buf.written());
}

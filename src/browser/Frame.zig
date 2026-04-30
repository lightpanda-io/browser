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
const AbstractRange = @import("webapi/AbstractRange.zig");
const MutationObserver = @import("webapi/MutationObserver.zig");
const IntersectionObserver = @import("webapi/IntersectionObserver.zig");
const Worker = @import("webapi/Worker.zig");
const CustomElementDefinition = @import("webapi/CustomElementDefinition.zig");
const PageTransitionEvent = @import("webapi/event/PageTransitionEvent.zig");
const SubmitEvent = @import("webapi/event/SubmitEvent.zig");
const NavigationKind = @import("webapi/navigation/root.zig").NavigationKind;
const KeyboardEvent = @import("webapi/event/KeyboardEvent.zig");
const MouseEvent = @import("webapi/event/MouseEvent.zig");

const HttpClient = @import("HttpClient.zig");

const timestamp = @import("../datetime.zig").timestamp;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

const WebApiURL = @import("webapi/URL.zig");
const GlobalEventHandlersLookup = @import("webapi/global_event_handlers.zig").Lookup;

const log = lp.log;
const String = lp.String;
const IFrame = Element.Html.IFrame;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

var default_url = WebApiURL{ ._raw = "about:blank" };
pub var default_location: Location = Location{ ._url = &default_url };

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
_event_target_attr_listeners: GlobalEventHandlersLookup = .empty,

// Blob URL registry for URL.createObjectURL/revokeObjectURL
_blob_urls: std.StringHashMapUnmanaged(*Blob) = .{},

/// `load` events that'll be fired before window's `load` event.
/// A call to `documentIsComplete` (which calls `_documentIsComplete`) resets it.
/// Double-buffered so that dispatching load events (which may trigger JS that
/// creates new elements) doesn't invalidate the list while iterating.
_to_load_1: std.ArrayList(*Element.Html) = .{},
_to_load_2: std.ArrayList(*Element.Html) = .{},
_to_load: *std.ArrayList(*Element.Html) = undefined,

_style_manager: StyleManager,
_script_manager: ScriptManager,

// List of active live ranges (for mutation updates per DOM spec)
_live_ranges: std.DoublyLinkedList = .{},

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

// DOM version used to invalidate cached state of "live" collections
version: usize = 0,

// This is maybe not great. It's a counter on the number of events that we're
// waiting on before triggering the "load" event. Essentially, we need all
// synchronous scripts and all iframes to be loaded. Scripts are handled by the
// ScriptManager, so all scripts just count as 1 pending load.
_pending_loads: u32,

_parent_notified: bool = false,

_type: enum { root, frame }, // only used for logs right now
_req_id: u32 = 0,
_navigated_options: ?NavigatedOpts = null,

pub fn init(self: *Frame, frame_id: u32, page: *Page, parent: ?*Frame) !void {
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.init", .{});
    }

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
        ._event_manager = EventManager.init(arena, self),
    };
    self._to_load = &self._to_load_1;

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
        ._frame = self,
        ._proto = undefined,
        ._document = self.document,
        ._location = &default_location,
        ._performance = Performance.init(),
        ._screen = screen,
        ._visual_viewport = visual_viewport,
        ._cross_origin_wrapper = undefined,
    });
    self.window._cross_origin_wrapper = .{ .window = self.window };

    self._style_manager = try StyleManager.init(self);
    errdefer self._style_manager.deinit();

    const browser = session.browser;
    self._script_manager = ScriptManager.init(browser.allocator, browser.http_client, self);
    errdefer self._script_manager.deinit();

    self.js = try browser.env.createContext(self, .{
        .identity = &page.identity,
        .identity_arena = arena,
        .call_arena = self.call_arena,
    });
    errdefer browser.env.destroyContext(self.js);

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

pub fn deinit(self: *Frame, abort_http: bool) void {
    for (self.child_frames.items) |frame| {
        frame.deinit(abort_http);
    }

    for (self.workers.items) |worker| {
        worker.deinit();
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

        {
            var node: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
            while (node) |n| {
                node = n.next; // capture before we potentially delete observer
                const observer: *MutationObserver = @fieldParentPtr("node", n);
                observer.releaseRef(page);
            }
        }

        for (self._intersection_observers.items) |observer| {
            observer.releaseRef(page);
        }

        var document = self.window._document;
        document._selection.releaseRef(page);

        if (document._fonts) |f| {
            f.releaseRef(page);
        }
    }

    const browser = page.session.browser;
    browser.env.destroyContext(self.js);

    self._script_manager.base.shutdown = true;

    if (self.parent == null) {
        browser.http_client.abort();
    } else if (abort_http) {
        // a small optimization, it's faster to abort _everything_ on the root
        // frame, so we prefer that. But if it's just the frame that's going
        // away (a frame navigation) then we'll abort the frame-related requests
        browser.http_client.abortFrame(self._frame_id);
    }

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

/// Look up a blob URL in this frame's registry.
pub fn lookupBlobUrl(self: *Frame, url: []const u8) ?*Blob {
    return self._blob_urls.get(url);
}

pub fn navigate(self: *Frame, request_url: [:0]const u8, opts: NavigateOpts) !void {
    lp.assert(self._load_state == .waiting, "frame.renavigate", .{});
    const session = self._session;
    self._load_state = .parsing;

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

        // even though this might be the same _data_ as `default_location`, we
        // have to do this to make sure window.location is at a unique _address_.
        // If we don't do this, multiple window._location will have the same
        // address and thus be mapped to the same v8::Object in the identity map.
        self.window._location = try Location.init(self.url, self);

        if (is_blob) {
            // strip out blob:
            self.origin = try URL.getOrigin(self.arena, request_url[5.. :0]);
        } else if (self.parent) |parent| {
            self.origin = parent.origin;
        } else if (self.window._opener) |opener| {
            self.origin = opener._frame.origin;
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
            var parser = Parser.init(parse_arena, self.document.asNode(), self);
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

        self.documentIsComplete();
        return;
    }

    var http_client = session.browser.http_client;

    self.url = try self.arena.dupeZ(u8, request_url);
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
    if (opts.header) |hdr| {
        try headers.add(hdr);
    }
    if (opts.referer) |ref| {
        const ref_header = try std.mem.concatWithSentinel(self.arena, u8, &.{ "Referer: ", ref }, 0);
        try headers.add(ref_header);
    }
    // We dispatch frame_navigate event before sending the request.
    // It ensures the event frame_navigated is not dispatched before this one.
    session.notification.dispatch(.frame_navigate, &.{
        .opts = opts,
        .url = self.url,
        .req_id = req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
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
        .params = .{
            .url = self.url,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .method = opts.method,
            .headers = headers,
            .body = opts.body,
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = self.url,
            .resource_type = .document,
            .notification = self._session.notification,
        },
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
        target.url = try target.arena.dupeZ(u8, resolved_url);
        target.window._location = try Location.init(target.url, target);
        if (target.parent == null) {
            try session.navigation.updateEntries(target.url, opts.kind, target, true);
        }
        // don't defer this, the caller is responsible for freeing it on error
        session.releaseArena(arena);
        return;
    }

    log.info(.browser, "schedule navigation", .{
        .url = resolved_url,
        .reason = opts.reason,
        .type = target._type,
    });

    // This is a micro-optimization. Terminate any inflight request as early
    // as we can. This will be more properly shutdown when we process the
    // scheduled navigation.
    if (target.parent == null) {
        session.browser.http_client.abort();
    } else {
        // This doesn't terminate any inflight requests for nested frames, but
        // again, this is just an optimization. We'll correctly shut down all
        // nested inflight requests when we process the navigation.
        session.browser.http_client.abortFrame(target._frame_id);
    }

    // Capture the originating frame's URL as the Referer for this
    // navigation. The originator's frame may be torn down before navigate()
    // runs (processRootQueuedNavigation rebuilds the Page in-place), so dup
    // into the QueuedNavigation arena which outlives that tear-down.
    var nav_opts = opts;
    if (nav_opts.referer == null and std.mem.startsWith(u8, originator.url, "http")) {
        nav_opts.referer = try arena.dupe(u8, originator.url);
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

pub fn scriptsCompletedLoading(self: *Frame) void {
    self.pendingLoadCompleted();
}

pub fn iframeCompletedLoading(self: *Frame, iframe: *IFrame) void {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    const entered = self.js.enter(&ls.handle_scope);
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

    // Run load events before window.load.
    try self.dispatchLoad();

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

fn frameHeaderDoneCallback(response: HttpClient.Response) !bool {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

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

    self.window._location = try Location.init(self.url, self);
    self.document._location = self.window._location;

    if (comptime IS_DEBUG) {
        log.debug(.frame, "navigate header", .{
            .url = self.url,
            .status = response.status(),
            .content_type = response.contentType(),
            .type = self._type,
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

    return true;
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

    var parser = Parser.init(parse_arena, self.document.asNode(), self);

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
        else => unreachable,
    }
}

fn frameErrorCallback(ctx: *anyopaque, err: anyerror) void {
    var self: *Frame = @ptrCast(@alignCast(ctx));

    log.err(.frame, "navigate failed", .{ .err = err, .type = self._type, .url = self.url });
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

    try Frame.init(new_frame, frame_id, self._page, self);
    errdefer new_frame.deinit(true);

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

    new_frame.navigate(url, .{
        .reason = .initialFrameNavigation,
        // Iframe's initial src request carries the parent's URL as Referer.
        // Parent frame outlives this navigate() call, so the slice is safe.
        .referer = if (std.mem.startsWith(u8, self.url, "http")) self.url else null,
    }) catch |err| {
        log.warn(.frame, "iframe navigate failure", .{ .url = url, .err = err });
        self._pending_loads -= 1;
        iframe._window = null;
        return error.IFrameLoadError;
    };

    // window[N] is based on document order. For now we'll just append the frame
    // at the end of our list and set child_frames_sorted == false. window.getFrame
    // will check this flag to decide if it needs to sort the frames or not.
    // But, we can optimize this a bit. Since we expect frames to often be
    // added in document order, we can do a quick check to see whether the list
    // is sorted or not.
    try self.child_frames.append(self.arena, new_frame);

    const frames_len = self.child_frames.items.len;
    if (frames_len == 1) {
        // this is the only frame, it must be sorted.
        return;
    }

    if (self.child_frames_sorted == false) {
        // the list already wasn't sorted, it still isn't
        return;
    }

    // So we added a frame into a sorted list. If this frame is sorted relative
    // to the last frame, it's still sorted
    const iframe_a = self.child_frames.items[frames_len - 2].iframe.?;
    const iframe_b = self.child_frames.items[frames_len - 1].iframe.?;

    if (iframe_a.asNode().compareDocumentPosition(iframe_b.asNode()) & 0x04 == 0) {
        // if b followed a, then & 0x04 = 0x04
        // but since we got 0, it means b does not follow a, and thus our list
        // is no longer sorted.
        self.child_frames_sorted = false;
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
    try Frame.init(popup, frame_id, page, null);
    errdefer popup.deinit(true);

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
    self.version += 1;

    if (self._intersection_check_scheduled) {
        return;
    }

    self._intersection_check_scheduled = true;
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
    if (node.isConnected() or node.isInShadowTree()) {
        var current = node;
        while (true) {
            if (current.is(ShadowRoot)) |shadow_root| {
                return shadow_root.getElementById(id, self);
            }
            const parent = current._parent orelse {
                if (current._type == .document) {
                    return current._type.document.getElementById(id, self);
                }
                if (IS_DEBUG) {
                    std.debug.assert(false);
                }
                return null;
            };
            current = parent;
        }
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

pub fn registerPerformanceObserver(self: *Frame, observer: *PerformanceObserver) !void {
    return self._performance_observers.append(self.arena, observer);
}

pub fn unregisterPerformanceObserver(self: *Frame, observer: *PerformanceObserver) void {
    for (self._performance_observers.items, 0..) |perf_observer, i| {
        if (perf_observer == observer) {
            _ = self._performance_observers.swapRemove(i);
            return;
        }
    }
}

/// Updates performance observers with the new entry.
/// This doesn't emit callbacks but rather fills the queues of observers.
pub fn notifyPerformanceObservers(self: *Frame, entry: *Performance.Entry) !void {
    for (self._performance_observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(self.arena, entry) catch |err| {
                log.err(.frame, "notifyPerformanceObservers", .{ .err = err, .type = self._type, .url = self.url });
            };
        }
    }

    try self.schedulePerformanceObserverDelivery();
}

/// Schedules async delivery of performance observer records.
pub fn schedulePerformanceObserverDelivery(self: *Frame) !void {
    // Already scheduled.
    if (self._performance_delivery_scheduled) {
        return;
    }
    self._performance_delivery_scheduled = true;

    return self.js.scheduler.add(
        self,
        struct {
            fn run(_frame: *anyopaque) anyerror!?u32 {
                const frame: *Frame = @ptrCast(@alignCast(_frame));
                frame._performance_delivery_scheduled = false;

                // Dispatch performance observer events.
                for (frame._performance_observers.items) |observer| {
                    if (observer.hasRecords()) {
                        try observer.dispatch(frame);
                    }
                }

                return null;
            }
        }.run,
        0,
        .{ .low_priority = true },
    );
}

pub fn registerMutationObserver(self: *Frame, observer: *MutationObserver) !void {
    observer.acquireRef();
    self._mutation_observers.append(&observer.node);
}

pub fn unregisterMutationObserver(self: *Frame, observer: *MutationObserver) void {
    observer.releaseRef(self._page);
    self._mutation_observers.remove(&observer.node);
}

pub fn registerIntersectionObserver(self: *Frame, observer: *IntersectionObserver) !void {
    observer.acquireRef();
    try self._intersection_observers.append(self.arena, observer);
}

pub fn unregisterIntersectionObserver(self: *Frame, observer: *IntersectionObserver) void {
    for (self._intersection_observers.items, 0..) |obs, i| {
        if (obs == observer) {
            observer.releaseRef(self._page);
            _ = self._intersection_observers.swapRemove(i);
            return;
        }
    }
}

pub fn checkIntersections(self: *Frame) !void {
    for (self._intersection_observers.items) |observer| {
        try observer.checkIntersections(self);
    }
}

pub fn dispatchLoad(self: *Frame) !void {
    const has_dom_load_listener = self._event_manager.has_dom_load_listener;

    // Swap buffers - new additions during dispatch go to the other buffer
    const to_process = self._to_load;
    self._to_load = if (self._to_load == &self._to_load_1)
        &self._to_load_2
    else
        &self._to_load_1;

    for (to_process.items) |html_element| {
        if (has_dom_load_listener or html_element.hasAttributeFunction(.onload, self)) {
            const event = try Event.initTrusted(comptime .wrap("load"), .{}, self._page);
            try self._event_manager.dispatch(html_element.asEventTarget(), event);
        }
    }

    to_process.clearRetainingCapacity();
}

pub fn scheduleMutationDelivery(self: *Frame) !void {
    if (self._mutation_delivery_scheduled) {
        return;
    }
    self._mutation_delivery_scheduled = true;
    try self.js.queueMutationDelivery();
}

pub fn scheduleIntersectionDelivery(self: *Frame) !void {
    if (self._intersection_delivery_scheduled) {
        return;
    }
    self._intersection_delivery_scheduled = true;
    try self.js.queueIntersectionDelivery();
}

pub fn scheduleSlotchangeDelivery(self: *Frame) !void {
    if (self._slotchange_delivery_scheduled) {
        return;
    }
    self._slotchange_delivery_scheduled = true;
    try self.js.queueSlotchangeDelivery();
}

pub fn performScheduledIntersectionChecks(self: *Frame) void {
    if (!self._intersection_check_scheduled) {
        return;
    }
    self._intersection_check_scheduled = false;
    self.checkIntersections() catch |err| {
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn deliverIntersections(self: *Frame) void {
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
            log.err(.frame, "frame.deliverIntersections", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn deliverMutations(self: *Frame) void {
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
        log.err(.frame, "frame.MutationLimit", .{ .type = self._type, .url = self.url });
        self._mutation_delivery_depth = 0;
        return;
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.deliverRecords(self) catch |err| {
            log.err(.frame, "frame.deliverMutations", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn deliverSlotchangeEvents(self: *Frame) void {
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
        log.err(.frame, "deliverSlotchange.append", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };

    var it = self._slots_pending_slotchange.keyIterator();
    while (it.next()) |slot| {
        slots[i] = slot.*;
        i += 1;
    }
    self._slots_pending_slotchange.clearRetainingCapacity();

    for (slots) |slot| {
        const event = Event.initTrusted(comptime .wrap("slotchange"), .{ .bubbles = true }, self._page) catch |err| {
            log.err(.frame, "deliverSlotchange.init", .{ .err = err, .type = self._type, .url = self.url });
            continue;
        };
        const target = slot.asNode().asEventTarget();
        self._event_manager.dispatch(target, event) catch |err| {
            log.err(.frame, "deliverSlotchange.dispatch", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
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

// called from the parser
pub fn appendNew(self: *Frame, parent: *Node, child: Node.NodeOrText) !void {
    const node = switch (child) {
        .node => |n| n,
        .text => |txt| blk: {
            // If we're appending this adjacently to a text node, we should merge
            if (parent.lastChild()) |sibling| {
                if (sibling.is(CData.Text)) |tn| {
                    const cdata = tn._proto;
                    const existing = cdata.getData().str();
                    cdata._data = try String.concat(self.arena, &.{ existing, txt });
                    return;
                }
            }
            break :blk try self.createTextNode(txt);
        },
    };

    lp.assert(node._parent == null, "Frame.appendNew", .{});
    try self._insertNodeRelative(true, parent, node, .append, .{
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
        Element.Html.Custom.invokeAdoptedCallbackOnElement(el, old_owner, new_owner, self);
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        try self.adoptNodeTree(child, old_owner, new_owner);
    }
}

pub fn createElementNS(self: *Frame, namespace: Element.Namespace, name: []const u8, attribute_iterator: anytype) !*Node {
    const from_parser = @TypeOf(attribute_iterator) == Parser.AttributeIterator;

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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("b"), ._tag = .b },
                    ),
                    'i' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("i"), ._tag = .i },
                    ),
                    'q' => return self.createHtmlElementT(
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("q"), ._tag = .quote },
                    ),
                    's' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("s"), ._tag = .s },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h1"), ._tag = .h1 },
                    ),
                    asUint("h2") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h2"), ._tag = .h2 },
                    ),
                    asUint("h3") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h3"), ._tag = .h3 },
                    ),
                    asUint("h4") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h4"), ._tag = .h4 },
                    ),
                    asUint("h5") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h5"), ._tag = .h5 },
                    ),
                    asUint("h6") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h6"), ._tag = .h6 },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("em"), ._tag = .em },
                    ),
                    asUint("dd") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("dd"), ._tag = .dd },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("dt"), ._tag = .dt },
                    ),
                    asUint("td") => return self.createHtmlElementT(
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("td"), ._tag = .td },
                    ),
                    asUint("th") => return self.createHtmlElementT(
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("th"), ._tag = .th },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("nav"), ._tag = .nav },
                    ),
                    asUint("del") => return self.createHtmlElementT(
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("del"), ._tag = .del },
                    ),
                    asUint("ins") => return self.createHtmlElementT(
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("ins"), ._tag = .ins },
                    ),
                    asUint("col") => return self.createHtmlElementT(
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("col"), ._tag = .col },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("sub"), ._tag = .sub },
                    ),
                    asUint("sup") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("sup"), ._tag = .sup },
                    ),
                    asUint("dfn") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("dfn"), ._tag = .dfn },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("main"), ._tag = .main },
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

                        // If frames's base url is not already set, fill it with
                        // the base tag.
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("menu"), ._tag = .menu },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("code"), ._tag = .code },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("aside"), ._tag = .aside },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("thead"), ._tag = .thead },
                    ),
                    asUint("tbody") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("tbody"), ._tag = .tbody },
                    ),
                    asUint("tfoot") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("tfoot"), ._tag = .tfoot },
                    ),
                    asUint("track") => return self.createHtmlElementT(
                        Element.Html.Track,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._kind = comptime .wrap("subtitles"), ._ready_state = .none },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("strong"), ._tag = .strong },
                    ),
                    asUint("header") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("header"), ._tag = .header },
                    ),
                    asUint("footer") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("footer"), ._tag = .footer },
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
                        IFrame,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("figure") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("figure"), ._tag = .figure },
                    ),
                    asUint("hgroup") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("hgroup"), ._tag = .hgroup },
                    ),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(name[0..7].*))) {
                    asUint("section") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("section"), ._tag = .section },
                    ),
                    asUint("article") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("article"), ._tag = .article },
                    ),
                    asUint("details") => return self.createHtmlElementT(
                        Element.Html.Details,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("summary") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("summary"), ._tag = .summary },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("marquee"), ._tag = .marquee },
                    ),
                    asUint("address") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("address"), ._tag = .address },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("colgroup"), ._tag = .colgroup },
                    ),
                    asUint("fieldset") => return self.createHtmlElementT(
                        Element.Html.FieldSet,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("frameset") => {
                        if (comptime from_parser) {
                            log.warn(.not_implemented, "framset", .{ .note = "<framset>...</frameset> in html is not handled properly" });
                        }
                        return self.createHtmlElementT(
                            Element.Html.FrameSet,
                            namespace,
                            attribute_iterator,
                            .{ ._proto = undefined },
                        );
                    },
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
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("noscript"), ._tag = .noscript },
                    ),
                    else => {},
                },
                10 => switch (@as(u80, @bitCast(name[0..10].*))) {
                    asUint("blockquote") => return self.createHtmlElementT(
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("blockquote"), ._tag = .blockquote },
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

                if (from_parser) {
                    // There are some things custom elements aren't allowed to do
                    // when we're parsing.
                    self.document._throw_on_dynamic_markup_insertion_counter += 1;
                }
                defer if (from_parser) {
                    self.document._throw_on_dynamic_markup_insertion_counter -= 1;
                };

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
                            null,
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

fn createHtmlElementT(self: *Frame, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype, html_element: E) !*Node {
    const html_element_ptr = try self._factory.htmlElement(html_element);
    const element = html_element_ptr.asElement();
    element._namespace = namespace;
    try self.populateElementAttributes(element, attribute_iterator);

    // Check for customized built-in element via "is" attribute
    try Element.Html.Custom.checkAndAttachBuiltIn(element, self);

    const node = element.asNode();
    if (@hasDecl(E, "Build") and @hasDecl(E.Build, "created")) {
        @call(.auto, @field(E.Build, "created"), .{ node, self }) catch |err| {
            log.err(.frame, "build.created", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
            return err;
        };
    }
    return node;
}

fn createHtmlMediaElementT(self: *Frame, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype) !*Node {
    const media_element = try self._factory.htmlMediaElement(E{ ._proto = undefined });
    const element = media_element.asElement();
    element._namespace = namespace;
    try self.populateElementAttributes(element, attribute_iterator);
    return element.asNode();
}

fn createSvgElementT(self: *Frame, comptime E: type, tag_name: []const u8, attribute_iterator: anytype, svg_element: E) !*Node {
    const svg_element_ptr = try self._factory.svgElement(tag_name, svg_element);
    var element = svg_element_ptr.asElement();
    element._namespace = .svg;
    try self.populateElementAttributes(element, attribute_iterator);
    return element.asNode();
}

fn populateElementAttributes(self: *Frame, element: *Element, list: anytype) !void {
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

// Called when `new MyElement()` is invoked directly in JS (not via the
// customElements.define/upgrade path). `new_target` is the constructor
// function that was used with `new`. We find the matching definition in the
// registry by function identity and allocate a detached Custom element with
// the registered tag name.
pub fn constructCustomElement(self: *Frame, new_target: JS.Function) !*Element {
    var it = self.window._custom_elements._definitions.iterator();
    const definition = while (it.next()) |entry| {
        if (entry.value_ptr.*.constructor.isEqual(new_target)) {
            break entry.value_ptr.*;
        }
    } else return error.IllegalConstructor;

    // Customized built-ins (`class Foo extends HTMLDivElement`, etc.) would
    // need to allocate the extended HTML type rather than Custom. Not yet
    // supported via direct `new` — upgrade path still works for those.
    if (definition.isCustomizedBuiltIn()) {
        return error.IllegalConstructor;
    }

    const tag_name = try String.init(self.arena, definition.name, .{});
    const node = try self.createHtmlElementT(Element.Html.Custom, .html, @as(?*Element.Attribute.List, null), .{
        ._proto = undefined,
        ._tag_name = tag_name,
        ._definition = definition,
    });
    return node.as(Element);
}

pub fn createTextNode(self: *Frame, text: []const u8) !*Node {
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .text = .{
            ._proto = undefined,
        } },
        ._data = try self.dupeSSO(text),
    });
    cd._type.text._proto = cd;
    return cd.asNode();
}

pub fn createComment(self: *Frame, text: []const u8) !*Node {
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .comment = .{
            ._proto = undefined,
        } },
        ._data = try self.dupeSSO(text),
    });
    cd._type.comment._proto = cd;
    return cd.asNode();
}

pub fn createCDATASection(self: *Frame, data: []const u8) !*Node {
    // Validate that the data doesn't contain "]]>"
    if (std.mem.indexOf(u8, data, "]]>") != null) {
        return error.InvalidCharacterError;
    }

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
        ._data = try self.dupeSSO(data),
    });

    // Set up the back pointer from Text to CData
    text_node._proto = cd;

    return cd.asNode();
}

pub fn createProcessingInstruction(self: *Frame, target: []const u8, data: []const u8) !*Node {
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

    const pi = try self._factory.create(CData.ProcessingInstruction{
        ._proto = undefined,
        ._target = owned_target,
    });

    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .processing_instruction = pi },
        ._data = try self.dupeSSO(data),
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
    switch (children.*) {
        .one => |n| {
            lp.assert(n == child, "Frame.removeNode.one", .{});
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

    // Update live ranges for removal (DOM spec remove steps 4-7)
    if (child_index_for_ranges) |idx| {
        self.updateRangesForNodeRemoval(parent, child, idx);
    }

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

        // If a <style> element is being removed, remove its sheet from the list
        if (el.is(Element.Html.Style)) |style| {
            if (style._sheet) |sheet| {
                if (self.document._style_sheets) |sheets| {
                    sheets.remove(sheet);
                }
                style._sheet = null;
            }
            self._style_manager.sheetModified();
        }
    }
}

pub fn appendNode(self: *Frame, parent: *Node, child: *Node, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, .append, opts);
}

pub fn appendAllChildren(self: *Frame, parent: *Node, target: *Node) !void {
    self.domChanged();
    const dest_connected = target.isConnected();

    // Use firstChild() instead of iterator to handle cases where callbacks
    // (like custom element connectedCallback) modify the parent during iteration.
    // The iterator captures "next" pointers that can become stale.
    while (parent.firstChild()) |child| {
        // Check if child was connected BEFORE removing it from parent
        const child_was_connected = child.isConnected();
        self.removeNode(parent, child, .{ .will_be_reconnected = dest_connected });
        try self.appendNode(target, child, .{ .child_already_connected = child_was_connected });
    }
}

pub fn insertAllChildrenBefore(self: *Frame, fragment: *Node, parent: *Node, ref_node: *Node) !void {
    self.domChanged();
    const dest_connected = parent.isConnected();

    // Use firstChild() instead of iterator to handle cases where callbacks
    // (like custom element connectedCallback) modify the fragment during iteration.
    // The iterator captures "next" pointers that can become stale.
    while (fragment.firstChild()) |child| {
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
pub fn insertNodeRelative(self: *Frame, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, relative, opts);
}
pub fn _insertNodeRelative(self: *Frame, comptime from_parser: bool, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    // caller should have made sure this was the case

    lp.assert(child._parent == null, "Frame.insertNodeRelative parent", .{});

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
            lp.assert(ref_node._parent.? == parent, "Frame.insertNodeRelative after", .{ .url = self.url });
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertAfter(&ref_node._child_link, &child._child_link);
        },
        .before => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Frame.insertNodeRelative before", .{ .url = self.url });
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertBefore(&ref_node._child_link, &child._child_link);
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
            // nodeComplete() callback is executed.
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
            try Element.Html.Custom.invokeConnectedCallbackOnElement(false, el, self);
        }
    }
}

pub fn attributeChange(self: *Frame, element: *Element, name: String, value: String, old_value: ?String) void {
    _ = Element.Build.call(element, "attributeChange", .{ element, name, value, self }) catch |err| {
        log.err(.bug, "build.attributeChange", .{ .tag = element.getTag(), .name = name, .value = value, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, value, null, self);

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.frame, "attributeChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
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

pub fn attributeRemove(self: *Frame, element: *Element, name: String, old_value: String) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, null, null, self);

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.frame, "attributeRemove.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
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

fn signalSlotChange(self: *Frame, slot: *Element.Html.Slot) void {
    self._slots_pending_slotchange.put(self.arena, slot, {}) catch |err| {
        log.err(.frame, "signalSlotChange.put", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };
    self.scheduleSlotchangeDelivery() catch |err| {
        log.err(.frame, "signalSlotChange.schedule", .{ .err = err, .type = self._type, .url = self.url });
    };
}

fn updateSlotAssignments(self: *Frame, element: *Element) void {
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

fn updateElementAssignedSlot(self: *Frame, element: *Element) void {
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
            log.err(.frame, "updateElementAssignedSlot.put", .{ .err = err, .type = self._type, .url = self.url });
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

pub fn hasMutationObservers(self: *const Frame) bool {
    return self._mutation_observers.first != null;
}

pub fn getCustomizedBuiltInDefinition(self: *Frame, element: *Element) ?*CustomElementDefinition {
    return self._customized_builtin_definitions.get(element);
}

pub fn setCustomizedBuiltInDefinition(self: *Frame, element: *Element, definition: *CustomElementDefinition) !void {
    try self._customized_builtin_definitions.put(self.arena, element, definition);
}

pub fn characterDataChange(
    self: *Frame,
    target: *Node,
    old_value: String,
) void {
    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyCharacterDataChange(target, old_value, self) catch |err| {
            log.err(.frame, "cdataChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn childListChange(
    self: *Frame,
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
            log.err(.frame, "childListChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
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
    const previous_parse_mode = self._parse_mode;
    self._parse_mode = .fragment;
    defer self._parse_mode = previous_parse_mode;

    var parser = Parser.init(self.call_arena, node, self);
    parser.parseFragment(html);

    // https://github.com/servo/html5ever/issues/583
    const children = node._children orelse return;
    const first = children.one;
    lp.assert(first.is(Element.Html.Html) != null, "Frame.parseHtmlAsChildren root", .{ .type = first._type });
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

fn nodeIsReady(self: *Frame, comptime from_parser: bool, node: *Node) !void {
    if ((comptime from_parser) and self._parse_mode == .fragment) {
        // we don't execute scripts added via innerHTML = '<script...';
        return;
    }
    if (node.is(Element.Html.Script)) |script| {
        if ((comptime from_parser == false) and script._src.len == 0) {
            // Script was added via JavaScript without a src attribute.
            // Only skip if it has no inline content either — scripts with
            // textContent/text should still execute per spec.
            if (node.firstChild() == null) {
                return;
            }
        }

        self.scriptAddedCallback(from_parser, script) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "script", .type = self._type, .url = self.url });
            return err;
        };
    } else if (node.is(IFrame)) |iframe| {
        self.iframeAddedCallback(iframe) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "iframe", .type = self._type, .url = self.url });
            return err;
        };
    } else if (node.is(Element.Html.Link)) |link| {
        link.linkAddedCallback(self) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "link", .type = self._type });
            return error.LinkLoadError;
        };
    } else if (node.is(Element.Html.Style)) |style| {
        style.styleAddedCallback(self) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "style", .type = self._type });
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

    fn deinit(self: *ParseState, frame: *Frame) void {
        switch (self.*) {
            .html => |html| frame.releaseArena(html.arena),
            else => {},
        }
    }
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

pub fn triggerMouseClick(self: *Frame, x: f64, y: f64) !void {
    const target = (try self.window._document.elementFromPoint(x, y, self)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse click", .{
            .url = self.url,
            .node = target,
            .x = x,
            .y = y,
            .type = self._type,
        });
    }
    const mouse_event: *MouseEvent = try .initTrusted(comptime .wrap("click"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, self);
    try self._event_manager.dispatch(target.asEventTarget(), mouse_event.asEvent());
}

// callback when the "click" event reaches the frame.
pub fn handleClick(self: *Frame, target: *Node) !void {
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

            if (try element.hasAttribute(comptime .wrap("download"), self)) {
                log.warn(.browser, "a.download", .{ .type = self._type, .url = self.url });
                return;
            }

            const target_frame = blk: {
                const target_name = anchor.getTarget();
                if (target_name.len == 0) {
                    break :blk target.ownerFrame(self);
                }
                break :blk self.resolveTargetFrame(target_name) orelse {
                    log.warn(.not_implemented, "target", .{ .type = self._type, .url = self.url, .target = target_name });
                    return;
                };
            };

            try element.focus(self);
            try self.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .{ .anchor = target_frame });
        },
        .input => |input| {
            try element.focus(self);
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            if (input._input_type == .submit or input._input_type == .image) {
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
        .label => |label| {
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl(self) orelse return;
            const control_html = control.is(Element.Html) orelse return;
            try control_html.click(self);
        },
        else => {},
    }
}

pub fn triggerKeyboard(self: *Frame, keyboard_event: *KeyboardEvent) !void {
    const event = keyboard_event.asEvent();
    const element = self.window._document._active_element orelse {
        event.deinit(self._page);
        return;
    };

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame keydown", .{
            .url = self.url,
            .node = element,
            .key = keyboard_event._key,
            .type = self._type,
        });
    }
    try self._event_manager.dispatch(element.asEventTarget(), event);
}

pub fn handleKeydown(self: *Frame, target: *Node, event: *Event) !void {
    const keyboard_event = event.is(KeyboardEvent) orelse return;
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
pub fn submitForm(self: *Frame, submitter_: ?*Element, form_: ?*Element.Html.Form, submit_opts: SubmitFormOpts) !void {
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
    const method = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formmethod"))) |fm| break :blk fm;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("method")) orelse "";
    };
    const is_post = std.ascii.eqlIgnoreCase(method, "post");

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
        if (is_post) {
            if (enctype_attr) |attr| {
                if (std.ascii.eqlIgnoreCase(attr, "multipart/form-data")) {
                    @import("../id.zig").uuidv4(&boundary_buf);
                    break :blk .{ .formdata = &boundary_buf };
                }
                if (!std.ascii.eqlIgnoreCase(attr, "application/x-www-form-urlencoded")) {
                    log.warn(.not_implemented, "FormData.encoding", .{ .encoding = attr });
                }
            }
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
        };
    } else {
        action = try URL.concatQueryString(arena, action, buf.written());
    }

    return self.scheduleNavigationWithArena(arena, action, opts, .{ .form = target_frame });
}

// insertText is a shortcut to insert text into the active element.
pub fn insertText(self: *Frame, v: []const u8) !void {
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
test "WebApi:Frame" {
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

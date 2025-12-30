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
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const IS_DEBUG = builtin.mode == .Debug;

const log = @import("../log.zig");

const Http = @import("../http/Http.zig");
const String = @import("../string.zig").String;

const Mime = @import("Mime.zig");
const Factory = @import("Factory.zig");
const Session = @import("Session.zig");
const Scheduler = @import("Scheduler.zig");
const EventManager = @import("EventManager.zig");
const ScriptManager = @import("ScriptManager.zig");

const Parser = @import("parser/Parser.zig");

const URL = @import("URL.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const CData = @import("webapi/CData.zig");
const Element = @import("webapi/Element.zig");
const Window = @import("webapi/Window.zig");
const Location = @import("webapi/Location.zig");
const Document = @import("webapi/Document.zig");
const ShadowRoot = @import("webapi/ShadowRoot.zig");
const Performance = @import("webapi/Performance.zig");
const Screen = @import("webapi/Screen.zig");
const PerformanceObserver = @import("webapi/PerformanceObserver.zig");
const MutationObserver = @import("webapi/MutationObserver.zig");
const IntersectionObserver = @import("webapi/IntersectionObserver.zig");
const CustomElementDefinition = @import("webapi/CustomElementDefinition.zig");
const storage = @import("webapi/storage/storage.zig");
const PageTransitionEvent = @import("webapi/event/PageTransitionEvent.zig");
const NavigationKind = @import("webapi/navigation/root.zig").NavigationKind;
const KeyboardEvent = @import("webapi/event/KeyboardEvent.zig");

const timestamp = @import("../datetime.zig").timestamp;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

const WebApiURL = @import("webapi/URL.zig");

var default_url = WebApiURL{ ._raw = "about:blank" };
pub var default_location: Location = Location{ ._url = &default_url };

pub const BUF_SIZE = 1024;

const Page = @This();

_session: *Session,

_event_manager: EventManager,

_parse_mode: enum { document, fragment, document_write },

// See Attribute.List for what this is. TL;DR: proper DOM Attribute Nodes are
// fat yet rarely needed. We only create them on-demand, but still need proper
// identity (a given attribute should return the same *Attribute), so we do
// a look here. We don't store this in the Element or Attribute.List.Entry
// because that would require additional space per element / Attribute.List.Entry
// even thoug we'll create very few (if any) actual *Attributes.
_attribute_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute),

// Same as _atlribute_lookup, but instead of individual attributes, this is for
// the return of elements.attributes.
_attribute_named_node_map_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute.NamedNodeMap),

// Lazily-created style, classList, and dataset objects. Only stored for elements
// that actually access these features via JavaScript, saving 24 bytes per element.
_element_styles: Element.StyleLookup = .{},
_element_datasets: Element.DatasetLookup = .{},
_element_class_lists: Element.ClassListLookup = .{},
_element_rel_lists: Element.RelListLookup = .{},
_element_shadow_roots: Element.ShadowRootLookup = .{},
_node_owner_documents: Node.OwnerDocumentLookup = .{},
_element_assigned_slots: Element.AssignedSlotLookup = .{},

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
_factory: Factory,

_load_state: LoadState,

_parse_state: ParseState,

_notified_network_idle: IdleNotification = .init,
_notified_network_almost_idle: IdleNotification = .init,

// A navigation event that happens from a script gets scheduled to run on the
// next tick.
_queued_navigation: ?QueuedNavigation = null,

// The URL of the current page
url: [:0]const u8,

// The base url specifies the base URL used to resolve the relative urls.
// It is set by a <base> tag.
// If null the url must be used.
base_url: ?[:0]const u8,

// Arbitrary buffer. Need to temporarily lowercase a value? Use this. No lifetime
// guarantee - it's valid until someone else uses it.
buf: [BUF_SIZE]u8,

// access to the JavaScript engine
js: *JS.Context,

// An arena for the lifetime of the page.
arena: Allocator,

// An arena with a lifetime guaranteed to be for 1 invoking of a Zig function
// from JS. Best arena to use, when possible.
call_arena: Allocator,

window: *Window,
document: *Document,

// DOM version used to invalidate cached state of "live" collections
version: usize,

scheduler: Scheduler,

_req_id: ?usize = null,
_navigated_options: ?NavigatedOpts = null,

pub fn init(arena: Allocator, call_arena: Allocator, session: *Session) !*Page {
    if (comptime IS_DEBUG) {
        log.debug(.page, "page.init", .{});
    }

    const page = try session.browser.allocator.create(Page);

    page.arena = arena;
    page.call_arena = call_arena;
    page._session = session;

    try page.reset(true);
    return page;
}

pub fn deinit(self: *Page) void {
    if (comptime IS_DEBUG) {
        log.debug(.page, "page.deinit", .{ .url = self.url });

        // Uncomment if you want slab statistics to print.
        // const stats = self._factory._slab.getStats(self.arena) catch unreachable;
        // var buffer: [256]u8 = undefined;
        // var stream = std.fs.File.stderr().writer(&buffer).interface;
        // stats.print(&stream) catch unreachable;
    }

    // some MicroTasks might be referencing the page, we need to drain it while
    // the page still exists
    self.js.runMicrotasks();

    const session = self._session;
    session.executor.removeContext();

    self._script_manager.shutdown = true;
    session.browser.http_client.abort();
    self._script_manager.deinit();
    session.browser.allocator.destroy(self);
}

fn reset(self: *Page, comptime initializing: bool) !void {
    if (comptime initializing == false) {
        self._session.executor.removeContext();
        self._script_manager.shutdown = true;
        self._session.browser.http_client.abort();
        self._script_manager.deinit();
        _ = self._session.browser.page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });
    }

    self._factory = Factory.init(self);
    self.scheduler = Scheduler.init(self.arena);

    self.version = 0;
    self.url = "about:blank";
    self.base_url = null;

    self.document = (try self._factory.document(Node.Document.HTMLDocument{ ._proto = undefined })).asDocument();

    const storage_bucket = try self._factory.create(storage.Bucket{});
    const screen = try Screen.init(self);
    self.window = try self._factory.eventTarget(Window{
        ._document = self.document,
        ._storage_bucket = storage_bucket,
        ._performance = Performance.init(),
        ._proto = undefined,
        ._location = &default_location,
        ._screen = screen,
    });
    self.window._document = self.document;
    self.window._location = &default_location;

    self._parse_state = .pre;
    self._load_state = .parsing;
    self._queued_navigation = null;
    self._parse_mode = .document;
    self._attribute_lookup = .empty;
    self._attribute_named_node_map_lookup = .empty;
    self._event_manager = EventManager.init(self);

    self._script_manager = ScriptManager.init(self);
    errdefer self._script_manager.deinit();

    self.js = try self._session.executor.createContext(self, true);
    errdefer self.js.deinit();

    self._element_styles = .{};
    self._element_datasets = .{};
    self._element_class_lists = .{};
    self._element_rel_lists = .{};
    self._element_shadow_roots = .{};
    self._node_owner_documents = .{};
    self._element_assigned_slots = .{};
    self._notified_network_idle = .init;
    self._notified_network_almost_idle = .init;

    self._performance_observers = .{};
    self._mutation_observers = .{};
    self._mutation_delivery_scheduled = false;
    self._mutation_delivery_depth = 0;
    self._intersection_observers = .{};
    self._intersection_check_scheduled = false;
    self._intersection_delivery_scheduled = false;
    self._slots_pending_slotchange = .{};
    self._slotchange_delivery_scheduled = false;
    self._customized_builtin_definitions = .{};
    self._customized_builtin_connected_callback_invoked = .{};
    self._customized_builtin_disconnected_callback_invoked = .{};
    self._undefined_custom_elements = .{};

    try self.registerBackgroundTasks();
}

pub fn base(self: *const Page) [:0]const u8 {
    return self.base_url orelse self.url;
}

fn registerBackgroundTasks(self: *Page) !void {
    if (comptime builtin.is_test) {
        // HTML test runner manually calls these as necessary
        return;
    }

    const Browser = @import("Browser.zig");

    try self.scheduler.add(self._session.browser, struct {
        fn runMessageLoop(ctx: *anyopaque) !?u32 {
            const b: *Browser = @ptrCast(@alignCast(ctx));
            b.runMessageLoop();
            return 250;
        }
    }.runMessageLoop, 250, .{ .name = "page.messageLoop" });
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

pub fn isSameOrigin(self: *const Page, url: [:0]const u8) !bool {
    const current_origin = (try URL.getOrigin(self.call_arena, self.url)) orelse return false;
    return std.mem.startsWith(u8, url, current_origin);
}

pub fn navigate(self: *Page, request_url: [:0]const u8, opts: NavigateOpts) !void {
    const session = self._session;
    if (self._parse_state != .pre) {
        // it's possible for navigate to be called multiple times on the
        // same page (via CDP). We want to reset the page between each call.
        try self.reset(false);
    }

    const req_id = self._session.browser.http_client.nextReqId();
    log.info(.page, "navigate", .{
        .url = request_url,
        .method = opts.method,
        .reason = opts.reason,
        .body = opts.body != null,
        .req_id = req_id,
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

        self._session.browser.notification.dispatch(.page_navigate, &.{
            .req_id = req_id,
            .opts = opts,
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        self._session.browser.notification.dispatch(.page_navigated, &.{
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
        _ = self._session.browser.http_client.incrReqId();
        return;
    }

    var http_client = self._session.browser.http_client;

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
    self._session.browser.notification.dispatch(.page_navigate, &.{
        .req_id = req_id,
        .opts = opts,
        .url = self.url,
        .timestamp = timestamp(.monotonic),
    });

    session.navigation._current_navigation_kind = opts.kind;

    http_client.request(.{
        .ctx = self,
        .url = self.url,
        .method = opts.method,
        .headers = headers,
        .body = opts.body,
        .cookie_jar = &self._session.cookie_jar,
        .resource_type = .document,
        .header_callback = pageHeaderDoneCallback,
        .data_callback = pageDataCallback,
        .done_callback = pageDoneCallback,
        .error_callback = pageErrorCallback,
    }) catch |err| {
        log.err(.page, "navigate request", .{ .url = self.url, .err = err });
        return err;
    };
}

// We cannot navigate immediately as navigating will delete the DOM tree,
// which holds this event's node.
// As such we schedule the function to be called as soon as possible.
// The page.arena is safe to use here, but the transfer_arena exists
// specifically for this type of lifetime.
pub fn scheduleNavigation(self: *Page, request_url: []const u8, opts: NavigateOpts, priority: NavigationPriority) !void {
    if (self.canScheduleNavigation(priority) == false) {
        if (comptime IS_DEBUG) {
            log.debug(.browser, "ignored navigation", .{
                .target = request_url,
                .reason = opts.reason,
            });
        }
        return;
    }

    const session = self._session;

    const resolved_url = try URL.resolve(
        session.transfer_arena,
        self.base(),
        request_url,
        .{ .always_dupe = true },
    );

    if (!opts.force and URL.eqlDocument(self.url, resolved_url)) {
        self.url = try self.arena.dupeZ(u8, resolved_url);
        self.window._location = try Location.init(self.url, self);
        self.document._location = self.window._location;
        return session.navigation.updateEntries(self.url, opts.kind, self, true);
    }

    log.info(.browser, "schedule navigation", .{
        .url = resolved_url,
        .reason = opts.reason,
        .target = resolved_url,
    });

    self._session.browser.http_client.abort();

    self._queued_navigation = .{
        .opts = opts,
        .url = resolved_url,
        .priority = priority,
    };
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
        log.err(.page, "document is loaded", .{ .err = err });
    };
}

pub fn _documentIsLoaded(self: *Page) !void {
    const event = try Event.initTrusted("DOMContentLoaded", .{ .bubbles = true }, self);
    try self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    );
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
        log.err(.page, "document is complete", .{ .err = err });
    };

    if (IS_DEBUG) {
        std.debug.assert(self._req_id != null);
        std.debug.assert(self._navigated_options != null);
    }

    self._session.browser.notification.dispatch(.page_navigated, &.{
        .req_id = self._req_id.?,
        .opts = self._navigated_options.?,
        .url = self.url,
        .timestamp = timestamp(.monotonic),
    });
}

fn _documentIsComplete(self: *Page) !void {
    self.document._ready_state = .complete;

    // dispatch window.load event
    const event = try Event.initTrusted("load", .{}, self);
    // this event is weird, it's dispatched directly on the window, but
    // with the document as the target
    event._target = self.document.asEventTarget();
    try self._event_manager.dispatchWithFunction(
        self.window.asEventTarget(),
        event,
        self.window._on_load,
        .{ .inject_target = false, .context = "page load" },
    );

    const pageshow_event = try PageTransitionEvent.initTrusted("pageshow", .{}, self);
    try self._event_manager.dispatchWithFunction(
        self.window.asEventTarget(),
        pageshow_event.asEvent(),
        self.window._on_pageshow,
        .{ .context = "page show" },
    );
}

fn pageHeaderDoneCallback(transfer: *Http.Transfer) !void {
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
        });
    }
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
            log.debug(.page, "navigate first chunk", .{ .content_type = mime.content_type, .len = data.len });
        }

        switch (mime.content_type) {
            .text_html => self._parse_state = .{ .html = .{} },
            .application_json, .text_javascript, .text_css, .text_plain => {
                var arr: std.ArrayListUnmanaged(u8) = .empty;
                try arr.appendSlice(self.arena, "<html><head><meta charset=\"utf-8\"></head><body><pre>");
                self._parse_state = .{ .text = arr };
            },
            else => self._parse_state = .{ .raw = .{} },
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
        .raw => |*buf| try buf.appendSlice(self.arena, data),
        .pre => unreachable,
        .complete => unreachable,
        .err => unreachable,
        .raw_done => unreachable,
    }
}

fn pageDoneCallback(ctx: *anyopaque) !void {
    if (comptime IS_DEBUG) {
        log.debug(.page, "navigate done", .{});
    }

    var self: *Page = @ptrCast(@alignCast(ctx));
    self.clearTransferArena();

    //We need to handle different navigation types differently.
    try self._session.navigation.commitNavigation(self);

    defer if (comptime IS_DEBUG) {
        log.debug(.page, "page.load.complete", .{ .url = self.url });
    };

    switch (self._parse_state) {
        .html => |buf| {
            var parser = Parser.init(self.arena, self.document.asNode(), self);
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
            var parser = Parser.init(self.arena, self.document.asNode(), self);
            parser.parse(buf.items);
            self.documentIsComplete();
        },
        .raw => |buf| {
            self._parse_state = .{ .raw_done = buf.items };
            self.documentIsComplete();
        },
        .pre => {
            // Received a response without a body like: https://httpbin.io/status/200
            // We assume we have received an OK status (checked in Client.headerCallback)
            // so we load a blank document to navigate away from any prior page.
            self._parse_state = .{ .complete = {} };
            self.documentIsComplete();
        },
        else => unreachable,
    }
}

fn pageErrorCallback(ctx: *anyopaque, err: anyerror) void {
    log.err(.page, "navigate failed", .{ .err = err });

    var self: *Page = @ptrCast(@alignCast(ctx));
    self.clearTransferArena();
    self._parse_state = .{ .err = err };
}

// The transfer arena is useful and interesting, but has a weird lifetime.
// When we're transferring from one page to another (via delayed navigation)
// we need things in memory: like the URL that we're navigating to and
// optionally the body to POST. That cannot exist in the page.arena, because
// the page that we have is going to be destroyed and a new page is going
// to be created. If we used the page.arena, we'd wouldn't be able to reset
// it between navigation.
// So the transfer arena is meant to exist between a navigation event. It's
// freed when the main html navigation is complete, either in pageDoneCallback
// or pageErrorCallback. It needs to exist for this long because, if we set
// a body, CURLOPT_POSTFIELDS does not copy the body (it optionally can, but
// why would we want to) and requires the body to live until the transfer
// is complete.
fn clearTransferArena(self: *Page) void {
    _ = self._session.browser.transfer_arena.reset(.{ .retain_with_limit = 4 * 1024 });
}

pub fn wait(self: *Page, wait_ms: u32) Session.WaitResult {
    return self._wait(wait_ms) catch |err| {
        switch (err) {
            error.JsError => {}, // already logged (with hopefully more context)
            else => {
                // There may be errors from the http/client or ScriptManager
                // that we should not treat as an error like this. Will need
                // to run this through more real-world sites and see if we need
                // to expand the switch (err) to have more customized logs for
                // specific messages.
                log.err(.browser, "page wait", .{ .err = err });
            },
        }
        return .done;
    };
}

fn _wait(self: *Page, wait_ms: u32) !Session.WaitResult {
    var timer = try std.time.Timer.start();
    var ms_remaining = wait_ms;

    var try_catch: JS.TryCatch = undefined;
    try_catch.init(self.js);
    defer try_catch.deinit();

    var scheduler = &self.scheduler;
    var http_client = self._session.browser.http_client;

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

    // for debugging
    // defer self.printWaitAnalysis();

    while (true) {
        switch (self._parse_state) {
            .pre, .raw, .text => {
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
                    std.debug.assert(exit_when_done == false);

                    // data on a socket we aren't handling, return to caller
                    return .cdp_socket;
                }
            },
            .html, .complete => {
                if (self._queued_navigation != null) {
                    return .navigate;
                }

                // The HTML page was parsed. We now either have JS scripts to
                // download, or scheduled tasks to execute, or both.

                // scheduler.run could trigger new http transfers, so do not
                // store http_client.active BEFORE this call and then use
                // it AFTER.
                const ms_to_next_task = try scheduler.run();

                if (try_catch.caught(self.call_arena)) |caught| {
                    log.info(.js, "page wait", .{ .caught = caught, .src = "scheduler" });
                }

                const http_active = http_client.active;
                const total_network_activity = http_active + http_client.intercepted;
                if (self._notified_network_almost_idle.check(total_network_activity <= 2)) {
                    self.notifyNetworkAlmostIdle();
                }
                if (self._notified_network_idle.check(total_network_activity == 0)) {
                    self.notifyNetworkIdle();
                }

                if (http_active == 0 and exit_when_done) {
                    // we don't need to consider http_client.intercepted here
                    // because exit_when_done is true, and that can only be
                    // the case when interception isn't possible.
                    std.debug.assert(http_client.intercepted == 0);

                    const ms = ms_to_next_task orelse blk: {
                        if (wait_ms - ms_remaining < 100) {
                            if (comptime builtin.is_test) {
                                return .done;
                            }
                            // Look, we want to exit ASAP, but we don't want
                            // to exit so fast that we've run none of the
                            // background jobs.
                            break :blk 50;
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
                    const ms_to_wait = @min(200, @min(ms_remaining, ms_to_next_task orelse 200));
                    if (try http_client.tick(ms_to_wait) == .cdp_socket) {
                        // data on a socket we aren't handling, return to caller
                        return .cdp_socket;
                    }
                }
            },
            .err => |err| {
                self._parse_state = .{ .raw_done = @errorName(err) };
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

fn printWaitAnalysis(self: *Page) void {
    std.debug.print("load_state: {s}\n", .{@tagName(self._load_state)});
    std.debug.print("parse_state: {s}\n", .{@tagName(std.meta.activeTag(self._parse_state))});
    {
        std.debug.print("\nactive requests: {d}\n", .{self._session.browser.http_client.active});
        var n_ = self._session.browser.http_client.handles.in_use.first;
        while (n_) |n| {
            const handle: *Http.Client.Handle = @fieldParentPtr("node", n);
            const transfer = Http.Transfer.fromEasy(handle.conn.easy) catch |err| {
                std.debug.print(" - failed to load transfer: {any}\n", .{err});
                break;
            };
            std.debug.print(" - {f}\n", .{transfer});
            n_ = n.next;
        }
    }

    {
        std.debug.print("\nqueued requests: {d}\n", .{self._session.browser.http_client.queue.len()});
        var n_ = self._session.browser.http_client.queue.first;
        while (n_) |n| {
            const transfer: *Http.Transfer = @fieldParentPtr("_node", n);
            std.debug.print(" - {f}\n", .{transfer});
            n_ = n.next;
        }
    }

    {
        std.debug.print("\ndeferreds: {d}\n", .{self._script_manager.defer_scripts.len()});
        var n_ = self._script_manager.defer_scripts.first;
        while (n_) |n| {
            const script: *ScriptManager.Script = @fieldParentPtr("node", n);
            std.debug.print(" - {s} complete: {any}\n", .{ script.url, script.complete });
            n_ = n.next;
        }
    }

    {
        std.debug.print("\nasyncs: {d}\n", .{self._script_manager.async_scripts.len()});
    }

    {
        std.debug.print("\nasyncs ready: {d}\n", .{self._script_manager.ready_scripts.len()});
        var n_ = self._script_manager.ready_scripts.first;
        while (n_) |n| {
            const script: *ScriptManager.Script = @fieldParentPtr("node", n);
            std.debug.print(" - {s} complete: {any}\n", .{ script.url, script.complete });
            n_ = n.next;
        }
    }

    const now = milliTimestamp(.monotonic);
    {
        std.debug.print("\nhigh_priority schedule: {d}\n", .{self.scheduler.high_priority.count()});
        var it = self.scheduler.high_priority.iterator();
        while (it.next()) |task| {
            std.debug.print(" - {s} schedule: {d}ms\n", .{ task.name, task.run_at - now });
        }
    }

    {
        std.debug.print("\nlow_priority schedule: {d}\n", .{self.scheduler.low_priority.count()});
        var it = self.scheduler.low_priority.iterator();
        while (it.next()) |task| {
            std.debug.print(" - {s} schedule: {d}ms\n", .{ task.name, task.run_at - now });
        }
    }
}

pub fn tick(self: *Page) void {
    if (comptime IS_DEBUG) {
        log.debug(.page, "tick", .{});
    }
    _ = self.scheduler.run() catch |err| {
        log.err(.page, "tick", .{ .err = err });
    };
    self.js.runMicrotasks();
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
            .src = script.asElement().getAttributeSafe("src"),
        });
    };
}

pub fn domChanged(self: *Page) void {
    self.version += 1;

    if (self._intersection_check_scheduled) {
        return;
    }

    self._intersection_check_scheduled = true;
    self.js.queueIntersectionChecks() catch |err| {
        log.err(.page, "page.schedIntersectChecks", .{ .err = err });
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
            std.debug.assert(false);
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
        const element_id = el.getAttributeSafe("id") orelse continue;
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
                log.err(.page, "notifyPerformanceObservers", .{ .err = err });
            };
        }
    }

    // Already scheduled.
    if (self._performance_delivery_scheduled) {
        return;
    }
    self._performance_delivery_scheduled = true;

    return self.scheduler.add(
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
        log.err(.page, "page.schedIntersectChecks", .{ .err = err });
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
            log.err(.page, "page.deliverIntersections", .{ .err = err });
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
        log.err(.page, "page.MutationLimit", .{});
        self._mutation_delivery_depth = 0;
        return;
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.deliverRecords(self) catch |err| {
            log.err(.page, "page.deliverMutations", .{ .err = err });
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
        log.err(.page, "deliverSlotchange.append", .{ .err = err });
        return;
    };

    var it = self._slots_pending_slotchange.keyIterator();
    while (it.next()) |slot| {
        slots[i] = slot.*;
        i += 1;
    }
    self._slots_pending_slotchange.clearRetainingCapacity();

    for (slots) |slot| {
        const event = Event.initTrusted("slotchange", .{ .bubbles = true }, self) catch |err| {
            log.err(.page, "deliverSlotchange.init", .{ .err = err });
            continue;
        };
        const target = slot.asNode().asEventTarget();
        _ = target.dispatchEvent(event, self) catch |err| {
            log.err(.page, "deliverSlotchange.dispatch", .{ .err = err });
        };
    }
}

fn notifyNetworkIdle(self: *Page) void {
    std.debug.assert(self._notified_network_idle == .done);
    self._session.browser.notification.dispatch(.page_network_idle, &.{
        .timestamp = timestamp(.monotonic),
    });
}

fn notifyNetworkAlmostIdle(self: *Page) void {
    std.debug.assert(self._notified_network_almost_idle == .done);
    self._session.browser.notification.dispatch(.page_network_almost_idle, &.{
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

    std.debug.assert(node._parent == null);
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
        log.err(.bug, "build.complete", .{ .tag = node.getNodeName(&self.buf), .err = err });
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
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = String.init(undefined, "dl", .{}) catch unreachable, ._tag = .dl },
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
                            if (n.as(Element).getAttributeSafe("href")) |href| {
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

                var caught: JS.TryCatch.Caught = undefined;
                _ = def.constructor.newInstance(&caught) catch |err| {
                    log.warn(.js, "custom element constructor", .{ .name = name, .err = err, .caught = caught });
                    return node;
                };

                // After constructor runs, invoke attributeChangedCallback for initial attributes
                const element = node.as(Element);
                if (element._attributes) |attributes| {
                    var it = attributes.iterator();
                    while (it.next()) |attr| {
                        Element.Html.Custom.invokeAttributeChangedCallbackOnElement(
                            element,
                            attr._name.str(),
                            null, // old_value is null for initial attributes
                            attr._value.str(),
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
            log.err(.page, "build.created", .{ .tag = node.getNodeName(&self.buf), .err = err });
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
    // Validate target doesn't contain "?>"
    if (std.mem.indexOf(u8, target, "?>") != null) {
        return error.InvalidCharacterError;
    }

    // Validate target follows XML name rules (similar to attribute name validation)
    try Element.Attribute.validateAttributeName(target);

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
            std.debug.assert(n == child);
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
                const slot_name = el.getAttributeSafe("slot") orelse "";
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
        if (el.getAttributeSafe("id")) |id| {
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
    std.debug.assert(child._parent == null);

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
            std.debug.assert(ref_node._parent.? == parent);
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertAfter(&ref_node._child_link, &child._child_link);
        },
        .before => |ref_node| {
            // caller should have made sure this was the case
            std.debug.assert(ref_node._parent.? == parent);
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
                if (el.getAttributeSafe("id")) |id| {
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
        if (el.getAttributeSafe("id")) |id| {
            try self.addElementId(el.asNode()._parent.?, el, id);
        }

        if (should_invoke_connected) {
            try Element.Html.Custom.invokeConnectedCallbackOnElement(false, el, self);
        }
    }
}

pub fn attributeChange(self: *Page, element: *Element, name: []const u8, value: []const u8, old_value: ?[]const u8) void {
    _ = Element.Build.call(element, "attributeChange", .{ element, name, value, self }) catch |err| {
        log.err(.bug, "build.attributeChange", .{ .tag = element.getTag(), .name = name, .value = value, .err = err });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, value, self);

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.page, "attributeChange.notifyObserver", .{ .err = err });
        };
    }

    // Handle slot assignment changes
    if (std.mem.eql(u8, name, "slot")) {
        self.updateSlotAssignments(element);
    } else if (std.mem.eql(u8, name, "name")) {
        // Check if this is a slot element
        if (element.is(Element.Html.Slot)) |slot| {
            self.signalSlotChange(slot);
        }
    }
}

pub fn attributeRemove(self: *Page, element: *Element, name: []const u8, old_value: []const u8) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, null, self);

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.page, "attributeRemove.notifyObserver", .{ .err = err });
        };
    }

    // Handle slot assignment changes
    if (std.mem.eql(u8, name, "slot")) {
        self.updateSlotAssignments(element);
    } else if (std.mem.eql(u8, name, "name")) {
        // Check if this is a slot element
        if (element.is(Element.Html.Slot)) |slot| {
            self.signalSlotChange(slot);
        }
    }
}

fn signalSlotChange(self: *Page, slot: *Element.Html.Slot) void {
    self._slots_pending_slotchange.put(self.arena, slot, {}) catch |err| {
        log.err(.page, "signalSlotChange.put", .{ .err = err });
        return;
    };
    self.scheduleSlotchangeDelivery() catch |err| {
        log.err(.page, "signalSlotChange.schedule", .{ .err = err });
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

    const slot_name = element.getAttributeSafe("slot") orelse "";

    // Recursively search through the shadow root for a matching slot
    if (findMatchingSlot(shadow_root.asNode(), slot_name)) |slot| {
        self._element_assigned_slots.put(self.arena, element, slot) catch |err| {
            log.err(.page, "updateElementAssignedSlot.put", .{ .err = err });
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
            log.err(.page, "cdataChange.notifyObserver", .{ .err = err });
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
            log.err(.page, "childListChange.notifyObserver", .{ .err = err });
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
    std.debug.assert(first.is(Element.Html.Html) != null);
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
            log.err(.page, "page.nodeIsReady", .{ .err = err });
            return err;
        };
    }
}

const ParseState = union(enum) {
    pre,
    complete,
    err: anyerror,
    html: std.ArrayListUnmanaged(u8),
    text: std.ArrayListUnmanaged(u8),
    raw: std.ArrayListUnmanaged(u8),
    raw_done: []const u8,
};

const LoadState = enum {
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

const QueuedNavigation = struct {
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
        });
    }
    const event = try @import("webapi/event/MouseEvent.zig").init("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, self);
    try self._event_manager.dispatch(target.asEventTarget(), event.asEvent());
}

// callback when the "click" event reaches the pages.
pub fn handleClick(self: *Page, target: *Node) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;
    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => |anchor| {
            const href = element.getAttributeSafe("href") orelse return;
            if (href.len == 0) {
                return;
            }

            if (std.mem.startsWith(u8, href, "javascript:")) {
                return;
            }

            // Check target attribute - don't navigate if opening in new window/tab
            const target_val = anchor.getTarget();
            if (target_val.len > 0 and !std.mem.eql(u8, target_val, "_self")) {
                log.warn(.not_implemented, "a.target", .{});
                return;
            }

            if (try element.hasAttribute("download", self)) {
                log.warn(.browser, "a.download", .{});
                return;
            }

            try self.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .anchor);
        },
        .input => |input| switch (input._input_type) {
            .submit => return self.submitForm(element, input.getForm(self)),
            else => self.window._document._active_element = element,
        },
        .button => |button| {
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return self.submitForm(element, button.getForm(self));
            }
        },
        .select, .textarea => self.window._document._active_element = element,
        else => {},
    }
}

pub fn triggerKeyboard(self: *Page, keyboard_event: *KeyboardEvent) !void {
    const element = self.window._document._active_element orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.page, "page keydown", .{
            .url = self.url,
            .node = element,
            .key = keyboard_event._key,
        });
    }
    try self._event_manager.dispatch(element.asEventTarget(), keyboard_event.asEvent());
}

pub fn handleKeydown(self: *Page, target: *Node, event: *Event) !void {
    const keyboard_event = event.as(KeyboardEvent);
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            return self.submitForm(input.asElement(), input.getForm(self));
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        // Handle printable characters
        if (key.isPrintable()) {
            // if the input is selected, replace the content.
            if (input._selected) {
                const new_value = try self.arena.dupe(u8, key.asString());
                try input.setValue(new_value, self);
                input._selected = false;
                return;
            }
            const current_value = input.getValue();
            const new_value = try std.mem.concat(self.arena, u8, &.{ current_value, key.asString() });
            try input.setValue(new_value, self);
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
        const current_value = textarea.getValue();
        const new_value = try std.mem.concat(self.arena, u8, &.{ current_value, append });
        return textarea.setValue(new_value, self);
    }
}

pub fn submitForm(self: *Page, submitter_: ?*Element, form_: ?*Element.Html.Form) !void {
    const form = form_ orelse return;

    if (submitter_) |submitter| {
        if (submitter.getAttributeSafe("disabled") != null) {
            return;
        }
    }
    const form_element = form.asElement();

    const FormData = @import("webapi/net/FormData.zig");
    // The submitter can be an input box (if enter was entered on the box)
    // I don't think this is technically correct, but FormData handles it ok
    const form_data = try FormData.init(form, submitter_, self);

    const transfer_arena = self._session.transfer_arena;

    const encoding = form_element.getAttributeSafe("enctype");

    var buf = std.Io.Writer.Allocating.init(transfer_arena);
    try form_data.write(encoding, &buf.writer);

    const method = form_element.getAttributeSafe("method") orelse "";
    var action = form_element.getAttributeSafe("action") orelse self.url;

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
        action = try URL.concatQueryString(transfer_arena, action, buf.written());
    }
    return self.scheduleNavigation(action, opts, .form);
}

// insertText is a shortcut to insert text into the active element.
pub fn insertText(self: *Page, v: []const u8) !void {
    const html_element = self.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        // If the input is selected, replace the existing value
        if (input._selected) {
            const new_value = try self.arena.dupe(u8, v);
            try input.setValue(new_value, self);
            input._selected = false;
            return;
        }

        // Or append the value
        const current_value = input.getValue();
        const new_value = try std.mem.concat(self.arena, u8, &.{ current_value, v });
        return input.setValue(new_value, self);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        const current_value = textarea.getValue();
        const new_value = try std.mem.concat(self.arena, u8, &.{ current_value, v });
        return textarea.setValue(new_value, self);
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

test "WebApi: Integration" {
    try testing.htmlRunner("integration", .{});
}

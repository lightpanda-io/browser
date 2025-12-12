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
const reflect = @import("reflect.zig");

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

const polyfill = @import("polyfill/polyfill.zig");

const Parser = @import("parser/Parser.zig");

const URL = @import("webapi/URL.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const CData = @import("webapi/CData.zig");
const Element = @import("webapi/Element.zig");
const Window = @import("webapi/Window.zig");
const Location = @import("webapi/Location.zig");
const Document = @import("webapi/Document.zig");
const DocumentFragment = @import("webapi/DocumentFragment.zig");
const ShadowRoot = @import("webapi/ShadowRoot.zig");
const Performance = @import("webapi/Performance.zig");
const Screen = @import("webapi/Screen.zig");
const HtmlScript = @import("webapi/Element.zig").Html.Script;
const MutationObserver = @import("webapi/MutationObserver.zig");
const IntersectionObserver = @import("webapi/IntersectionObserver.zig");
const CustomElementDefinition = @import("webapi/CustomElementDefinition.zig");
const storage = @import("webapi/storage/storage.zig");
const PageTransitionEvent = @import("webapi/event/PageTransitionEvent.zig");
const NavigationKind = @import("webapi/navigation/root.zig").NavigationKind;

const timestamp = @import("../datetime.zig").timestamp;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

pub threadlocal var current: *Page = undefined;
var default_url = URL{ ._raw = "about:blank" };
pub var default_location: Location = Location{ ._url = &default_url };

pub const BUF_SIZE = 1024;

const Page = @This();

_session: *Session,

_event_manager: EventManager,

_parse_mode: enum { document, fragment },

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
_element_shadow_roots: Element.ShadowRootLookup = .{},

_script_manager: ScriptManager,

// List of active MutationObservers
_mutation_observers: std.ArrayList(*MutationObserver) = .{},
_mutation_delivery_scheduled: bool = false,
_mutation_delivery_depth: u32 = 0,

// List of active IntersectionObservers
_intersection_observers: std.ArrayList(*IntersectionObserver) = .{},
_intersection_delivery_scheduled: bool = false,

// Lookup for customized built-in elements. Maps element pointer to definition.
_customized_builtin_definitions: std.AutoHashMapUnmanaged(*Element, *CustomElementDefinition) = .{},
_customized_builtin_connected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},
_customized_builtin_disconnected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},

// This is set when an element is being upgraded (constructor is called).
// The constructor can access this to get the element being upgraded.
_upgrading_element: ?*Node = null,

// List of custom elements that were created before their definition was registered
_undefined_custom_elements: std.ArrayList(*Element.Html.Custom) = .{},

_polyfill_loader: polyfill.Loader = .{},

// for heap allocations and managing WebAPI objects
_factory: Factory,

_load_state: LoadState,

_parse_state: ParseState,

_notified_network_idle: IdleNotification = .init,
_notified_network_almost_idle: IdleNotification = .init,

// The URL of the current page
url: [:0]const u8,

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

pub fn init(arena: Allocator, call_arena: Allocator, session: *Session) !*Page {
    if (comptime IS_DEBUG) {
        log.debug(.page, "page.init", .{});
    }

    const page = try arena.create(Page);

    page.arena = arena;
    page.call_arena = call_arena;
    page._session = session;

    page.scheduler = Scheduler.init(page.arena);
    try page.reset(true);
    current = page;
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

    // removeContext() will execute the destructor of any type that
    // registered a destructor (e.g. XMLHttpRequest).
    // Should be called before we deinit the page, because these objects
    // could be referencing it.
    self._session.executor.removeContext();

    self._script_manager.shutdown = true;
    self._session.browser.http_client.abort();
    self._script_manager.deinit();
}

fn reset(self: *Page, comptime initializing: bool) !void {
    if (comptime initializing == false) {
        self.scheduler.reset();
    }

    self._factory = Factory.init(self);

    self.version = 0;
    self.url = "about:blank";

    self.document = (try self._factory.document(Node.Document.HTMLDocument{ ._proto = undefined })).asDocument();

    if (comptime initializing == true) {
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
    } else {
        self.window._document = self.document;
        self.window._location = &default_location;
        // TODO reset _custom_elements?
    }

    self._parse_state = .pre;
    self._load_state = .parsing;
    self._attribute_lookup = .empty;
    self._attribute_named_node_map_lookup = .empty;
    self._event_manager = EventManager.init(self);

    self._script_manager = ScriptManager.init(self);
    errdefer self._script_manager.deinit();

    if (comptime initializing == true) {
        self.js = try self._session.executor.createContext(self, true, JS.GlobalMissingCallback.init(&self._polyfill_loader));
        errdefer self.js.deinit();
    }

    self._element_styles = .{};
    self._element_datasets = .{};
    self._element_class_lists = .{};
    self._element_shadow_roots = .{};
    self._notified_network_idle = .init;
    self._notified_network_almost_idle = .init;

    self._mutation_observers = .{};
    self._mutation_delivery_scheduled = false;
    self._mutation_delivery_depth = 0;
    self._intersection_observers = .{};
    self._intersection_delivery_scheduled = false;
    self._customized_builtin_definitions = .{};
    self._customized_builtin_connected_callback_invoked = .{};
    self._customized_builtin_disconnected_callback_invoked = .{};
    self._undefined_custom_elements = .{};

    try self.registerBackgroundTasks();
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

pub fn navigate(self: *Page, request_url: [:0]const u8, opts: NavigateOpts, kind: NavigationKind) !void {
    const session = self._session;

    const resolved_url = try URL.resolve(
        session.transfer_arena,
        self.url,
        request_url,
        .{ .always_dupe = true },
    );

    // setting opts.force = true will force a page load.
    // otherwise, we will need to ensure this is a true (not document) navigation.
    if (!opts.force) {
        // If we are navigating within the same document, just change URL.
        if (URL.eqlDocument(self.url, resolved_url)) {
            // update page url
            self.url = resolved_url;

            // update location
            self.window._location = try Location.init(self.url, self);
            self.document._location = self.window._location;

            try session.navigation.updateEntries(resolved_url, kind, self, true);
            return;
        }
    }

    if (self._parse_state != .pre) {
        // it's possible for navigate to be called multiple times on the
        // same page (via CDP). We want to reset the page between each call.
        try self.reset(false);
    }

    log.info(.page, "navigate", .{
        .url = request_url,
        .method = opts.method,
        .reason = opts.reason,
        .body = opts.body != null,
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
            .opts = opts,
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        self._session.browser.notification.dispatch(.page_navigated, &.{
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        return;
    }

    var http_client = self._session.browser.http_client;

    self.url = try self.arena.dupeZ(u8, request_url);

    var headers = try http_client.newHeaders();
    if (opts.header) |hdr| {
        try headers.add(hdr);
    }
    try self.requestCookie(.{ .is_navigation = true }).headersForRequest(self.arena, self.url, &headers);

    // We dispatch page_navigate event before sending the request.
    // It ensures the event page_navigated is not dispatched before this one.
    self._session.browser.notification.dispatch(.page_navigate, &.{
        .opts = opts,
        .url = self.url,
        .timestamp = timestamp(.monotonic),
    });

    session.navigation._current_navigation_kind = kind;

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
    const event = try Event.init("DOMContentLoaded", .{ .bubbles = true }, self);
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

    self._session.browser.notification.dispatch(.page_navigated, &.{
        .url = self.url,
        .timestamp = timestamp(.monotonic),
    });
}

fn _documentIsComplete(self: *Page) !void {
    self.document._ready_state = .complete;

    // dispatch window.load event
    const event = try Event.init("load", .{}, self);
    // this event is weird, it's dispatched directly on the window, but
    // with the document as the target
    event._target = self.document.asEventTarget();
    try self._event_manager.dispatchWithFunction(
        self.window.asEventTarget(),
        event,
        self.window._on_load,
        .{ .inject_target = false, .context = "page load" },
    );

    const pageshow_event = try PageTransitionEvent.init("pageshow", .{}, self);
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

    log.debug(.page, "navigate header", .{
        .url = self.url,
        .status = header.status,
        .content_type = header.contentType(),
    });
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

    // I'd like the page to know NOTHING about extra_socket / CDP, but the
    // fact is that the behavior of wait changes depending on whether or
    // not we're using CDP.
    // If we aren't using CDP, as soon as we think there's nothing left
    // to do, we can exit - we'de done.
    // But if we are using CDP, we should wait for the whole `wait_ms`
    // because the http_click.tick() also monitors the CDP socket. And while
    // we could let CDP poll http (like it does for HTTP requests), the fact
    // is that we know more about the timing of stuff (e.g. how long to
    // poll/sleep) in the page.
    const exit_when_done = http_client.extra_socket == null;

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
                self.js.runMicrotasks();

                // Either we have active http connections, or we're in CDP
                // mode with an extra socket. Either way, we're waiting
                // for http traffic
                if (try http_client.tick(@intCast(ms_remaining)) == .extra_socket) {
                    // exit_when_done is explicitly set when there isn't
                    // an extra socket, so it should not be possibl to
                    // get an extra_socket message when exit_when_done
                    // is true.
                    std.debug.assert(exit_when_done == false);

                    // data on a socket we aren't handling, return to caller
                    return .extra_socket;
                }
            },
            .html, .complete => {
                // The HTML page was parsed. We now either have JS scripts to
                // download, or scheduled tasks to execute, or both.

                // scheduler.run could trigger new http transfers, so do not
                // store http_client.active BEFORE this call and then use
                // it AFTER.
                const ms_to_next_task = try scheduler.run();

                if (try_catch.hasCaught()) {
                    const msg = (try try_catch.err(self.arena)) orelse "unknown";
                    log.info(.js, "page wait", .{ .err = msg, .src = "scheduler" });
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
                    // an extra_socket registered with the http client).
                    // We should continue to run lowPriority tasks, so we
                    // minimize how long we'll poll for network I/O.
                    const ms_to_wait = @min(200, @min(ms_remaining, ms_to_next_task orelse 200));
                    if (try http_client.tick(ms_to_wait) == .extra_socket) {
                        // data on a socket we aren't handling, return to caller
                        return .extra_socket;
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

pub fn tick(self: *Page) void {
    if (comptime IS_DEBUG) {
        log.debug(.page, "tick", .{});
    }
    _ = self.scheduler.run() catch |err| {
        log.err(.page, "tick", .{ .err = err });
    };
    self.js.runMicrotasks();
}

pub fn scriptAddedCallback(self: *Page, script: *HtmlScript) !void {
    self._script_manager.addFromElement(script, "parsing") catch |err| {
        log.err(.page, "page.scriptAddedCallback", .{
            .err = err,
            .src = script.asElement().getAttributeSafe("src"),
        });
    };
}

pub fn domChanged(self: *Page) void {
    self.version += 1;
}

pub fn getElementIdMap(page: *Page, node: *Node) *std.StringHashMapUnmanaged(*Element) {
    if (node.is(ShadowRoot)) |shadow_root| {
        return &shadow_root._elements_by_id;
    }

    var parent = node._parent;
    while (parent) |n| {
        if (n.is(ShadowRoot)) |shadow_root| {
            return &shadow_root._elements_by_id;
        }
        parent = n._parent;
    }
    return &page.document._elements_by_id;
}

pub fn addElementId(self: *Page, parent: *Node, element: *Element, id: []const u8) !void {
    var id_map = self.getElementIdMap(parent);
    const gop = try id_map.getOrPut(self.arena, id);
    if (!gop.found_existing) {
        gop.value_ptr.* = element;
    }
}

pub fn removeElementId(self: *Page, element: *Element, id: []const u8) void {
    var id_map = self.getElementIdMap(element.asNode());
    _ = id_map.remove(id);
}

pub fn getElementByIdFromNode(self: *Page, node: *Node, id: []const u8) ?*Element {
    const id_map = self.getElementIdMap(node);
    return id_map.get(id);
}

pub fn registerMutationObserver(self: *Page, observer: *MutationObserver) !void {
    try self._mutation_observers.append(self.arena, observer);
}

pub fn unregisterMutationObserver(self: *Page, observer: *MutationObserver) void {
    for (self._mutation_observers.items, 0..) |obs, i| {
        if (obs == observer) {
            _ = self._mutation_observers.swapRemove(i);
            return;
        }
    }
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
    // Only queue if not already scheduled
    if (self._mutation_delivery_scheduled) {
        return;
    }
    self._mutation_delivery_scheduled = true;

    // Queue mutation delivery as a microtask
    try self.js.queueMutationDelivery();
}

pub fn scheduleIntersectionDelivery(self: *Page) !void {
    // Only queue if not already scheduled
    if (self._intersection_delivery_scheduled) {
        return;
    }
    self._intersection_delivery_scheduled = true;

    // Queue intersection delivery as a microtask
    try self.js.queueIntersectionDelivery();
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

    // Iterate backwards to handle observers that disconnect during their callback
    var i = self._mutation_observers.items.len;
    while (i > 0) {
        i -= 1;
        const observer = self._mutation_observers.items[i];
        observer.deliverRecords(self) catch |err| {
            log.err(.page, "page.deliverMutations", .{ .err = err });
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
        log.err(.bug, "build.complete", .{ .tag = node.getNodeName(self), .err = err });
        return err;
    };
    return self.nodeIsReady(true, node);
}

pub fn createElement(self: *Page, ns_: ?[]const u8, name: []const u8, attribute_iterator: anytype) !*Node {
    const namespace: Element.Namespace = blk: {
        const ns = ns_ orelse break :blk .html;
        if (std.mem.eql(u8, ns, "http://www.w3.org/2000/svg")) break :blk .svg;
        if (std.mem.eql(u8, ns, "http://www.w3.org/1998/Math/MathML")) break :blk .mathml;
        if (std.mem.eql(u8, ns, "http://www.w3.org/XML/1998/namespace")) break :blk .xml;
        break :blk .html;
    };

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
            else => {},
        },
        4 => switch (@as(u32, @bitCast(name[0..4].*))) {
            asUint("span") => return self.createHtmlElementT(
                Element.Html.Generic,
                namespace,
                attribute_iterator,
                .{ ._proto = undefined, ._tag_name = String.init(undefined, "span", .{}) catch unreachable, ._tag = .span },
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
            asUint("dialog") => return self.createHtmlElementT(
                Element.Html.Dialog,
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
            else => {},
        },
        else => {},
    }

    if (namespace == .svg) {
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

        var result: JS.Function.Result = undefined;
        _ = def.constructor.newInstance(&result) catch |err| {
            log.warn(.js, "custom element constructor", .{ .name = name, .err = err });
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

    child._parent = null;
    child._child_link = .{};

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
            self.removeElementId(el, id);
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

pub fn insertAllChildrenBefore(self: *Page, fragment: *Node, target: *Node, ref_node: *Node) !void {
    self.domChanged();
    const dest_connected = target.isConnected();

    var it = fragment.childrenIterator();
    while (it.next()) |child| {
        // Check if child was connected BEFORE removing it from fragment
        const child_was_connected = child.isConnected();
        self.removeNode(fragment, child, .{ .will_be_reconnected = dest_connected });
        try self.insertNodeRelative(
            target,
            child,
            .{ .before = ref_node },
            .{ .child_already_connected = child_was_connected },
        );
    }
}

fn _appendNode(self: *Page, comptime from_parser: bool, parent: *Node, child: *Node, opts: InsertNodeOpts) !void {
    self._insertNodeRelative(from_parser, parent, child, .append, opts);
}

const InsertNodeRelative = union(enum) {
    append,
    after: *Node,
    before: *Node,
};
const InsertNodeOpts = struct { child_already_connected: bool = false };
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
            if (el.getAttributeSafe("id")) |id| {
                try self.addElementId(parent, el, id);
            }

            // Invoke connectedCallback for custom elements during parsing
            // For main document parsing, we know nodes are connected (fast path)
            // For fragment parsing (innerHTML), we need to check connectivity
            if (self._parse_mode == .document or child.isConnected()) {
                try Element.Html.Custom.invokeConnectedCallbackOnElement(true, el, self);
            }
        }
        return;
    }

    if (opts.child_already_connected) {
        // The child is already connected, we don't have to reconnect it
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

    for (self._mutation_observers.items) |observer| {
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.page, "attributeChange.notifyObserver", .{ .err = err });
        };
    }
}

pub fn attributeRemove(self: *Page, element: *Element, name: []const u8, old_value: []const u8) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, null, self);

    for (self._mutation_observers.items) |observer| {
        observer.notifyAttributeChange(element, name, old_value, self) catch |err| {
            log.err(.page, "attributeRemove.notifyObserver", .{ .err = err });
        };
    }
}

pub fn hasMutationObservers(self: *const Page) bool {
    return self._mutation_observers.items.len > 0;
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
    // Notify mutation observers
    for (self._mutation_observers.items) |observer| {
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

    // Notify mutation observers
    for (self._mutation_observers.items) |observer| {
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

        self.scriptAddedCallback(script) catch |err| {
            log.err(.page, "page.nodeIsReady", .{ .err = err });
            return err;
        };
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

pub fn isSameOrigin(self: *const Page, url: [:0]const u8) !bool {
    const URLRaw = @import("URL.zig");
    const current_origin = (try URLRaw.getOrigin(self.arena, self.url)) orelse return false;
    return std.mem.startsWith(u8, url, current_origin);
}

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
};

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

const testing = @import("../testing.zig");
test "WebApi: Page" {
    try testing.htmlRunner("page", .{});
}

test "WebApi: Integration" {
    try testing.htmlRunner("integration", .{});
}

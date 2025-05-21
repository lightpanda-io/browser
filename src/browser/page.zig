// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const Dump = @import("dump.zig");
const Mime = @import("mime.zig").Mime;
const DataURI = @import("datauri.zig").DataURI;
const Session = @import("session.zig").Session;
const Renderer = @import("renderer.zig").Renderer;
const SessionState = @import("env.zig").SessionState;
const Window = @import("html/window.zig").Window;
const Walker = @import("dom/walker.zig").WalkerDepthFirst;
const Env = @import("env.zig").Env;
const Loop = @import("../runtime/loop.zig").Loop;
const HTMLDocument = @import("html/document.zig").HTMLDocument;

const URL = @import("../url.zig").URL;

const parser = @import("netsurf.zig");
const http = @import("../http/client.zig");
const storage = @import("storage/storage.zig");

const polyfill = @import("polyfill/polyfill.zig");

const log = std.log.scoped(.page);

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
// The page handle all its memory in an arena allocator. The arena is reseted
// when end() is called.
pub const Page = struct {
    session: *Session,

    // an arena with a lifetime for the entire duration of the page
    arena: Allocator,

    // Gets injected into any WebAPI method that needs it
    state: SessionState,

    // Serves are the root object of our JavaScript environment
    window: Window,

    // The URL of the page
    url: URL,

    raw_data: ?[]const u8,

    renderer: Renderer,

    microtask_node: Loop.CallbackNode,

    window_clicked_event_node: parser.EventNode,

    scope: *Env.Scope,

    // List of modules currently fetched/loaded.
    module_map: std.StringHashMapUnmanaged([]const u8),

    // current_script is the script currently evaluated by the page.
    // current_script could by fetch module to resolve module's url to fetch.
    current_script: ?*const Script = null,

    pub fn init(self: *Page, arena: Allocator, session: *Session) !void {
        const browser = session.browser;
        self.* = .{
            .window = try Window.create(null, null),
            .arena = arena,
            .raw_data = null,
            .url = URL.empty,
            .session = session,
            .renderer = Renderer.init(arena),
            .microtask_node = .{ .func = microtaskCallback },
            .window_clicked_event_node = .{ .func = windowClicked },
            .state = .{
                .arena = arena,
                .url = &self.url,
                .window = &self.window,
                .renderer = &self.renderer,
                .loop = browser.app.loop,
                .cookie_jar = &session.cookie_jar,
                .request_factory = browser.http_client.requestFactory(browser.notification),
            },
            .scope = try session.executor.startScope(&self.window, &self.state, self, true),
            .module_map = .empty,
        };

        // load polyfills
        try polyfill.load(self.arena, self.scope);

        // _ = try session.browser.app.loop.timeout(1 * std.time.ns_per_ms, &self.microtask_node);
    }

    fn microtaskCallback(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *Page = @fieldParentPtr("microtask_node", node);
        self.session.browser.runMicrotasks();
        repeat_delay.* = 1 * std.time.ns_per_ms;
    }

    // dump writes the page content into the given file.
    pub fn dump(self: *const Page, out: std.fs.File) !void {
        if (self.raw_data) |raw_data| {
            // raw_data was set if the document was not HTML, dump the data content only.
            return try out.writeAll(raw_data);
        }

        // if the page has a pointer to a document, dumps the HTML.
        const doc = parser.documentHTMLToDocument(self.window.document);
        try Dump.writeHTML(doc, out);
    }

    pub fn fetchModuleSource(ctx: *anyopaque, specifier: []const u8) !?[]const u8 {
        const self: *Page = @ptrCast(@alignCast(ctx));

        log.debug("fetch module: specifier: {s}", .{specifier});

        const base = if (self.current_script) |s| s.src else null;

        const file_src = blk: {
            if (base) |_base| {
                break :blk try URL.stitch(self.arena, specifier, _base);
            } else break :blk specifier;
        };

        if (self.module_map.get(file_src)) |module| return module;

        const module = try self.fetchData(specifier, base);
        if (module) |_module| try self.module_map.putNoClobber(self.arena, file_src, _module);
        return module;
    }

    pub fn wait(self: *Page) !void {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(self.scope);
        defer try_catch.deinit();

        try self.session.browser.app.loop.run();

        if (try_catch.hasCaught() == false) {
            log.debug("wait: OK", .{});
            return;
        }

        const msg = (try try_catch.err(self.arena)) orelse "unknown";
        log.info("wait error: {s}", .{msg});
    }

    pub fn origin(self: *const Page, arena: Allocator) ![]const u8 {
        var arr: std.ArrayListUnmanaged(u8) = .{};
        try self.url.origin(arr.writer(arena));
        return arr.items;
    }

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    pub fn navigate(self: *Page, request_url: URL, opts: NavigateOpts) !void {
        const arena = self.arena;
        const session = self.session;
        const notification = session.browser.notification;

        log.debug("starting GET {s}", .{request_url});

        // if the url is about:blank, nothing to do.
        if (std.mem.eql(u8, "about:blank", request_url.raw)) {
            var fbs = std.io.fixedBufferStream("");
            try self.loadHTMLDoc(fbs.reader(), "utf-8");
            // We do not processHTMLDoc here as we know we don't have any scripts
            // This assumption may be false when CDP Page.addScriptToEvaluateOnNewDocument is implemented
            try HTMLDocument.documentIsComplete(self.window.document, &self.state);
            return;
        }

        // we don't clone url, because we're going to replace self.url
        // later in this function, with the final request url (since we might
        // redirect)
        self.url = request_url;

        // load the data
        var request = try self.newHTTPRequest(.GET, &self.url, .{ .navigation = true });
        defer request.deinit();
        request.notification = notification;

        notification.dispatch(.page_navigate, &.{
            .opts = opts,
            .url = &self.url,
            .timestamp = timestamp(),
        });

        var response = try request.sendSync(.{});

        // would be different than self.url in the case of a redirect
        self.url = try URL.fromURI(arena, request.request_uri);

        const header = response.header;
        try session.cookie_jar.populateFromResponse(&self.url.uri, &header);

        // TODO handle fragment in url.
        try self.window.replaceLocation(.{ .url = try self.url.toWebApi(arena) });

        log.info("GET {any} {d}", .{ self.url, header.status });

        const content_type = header.get("content-type");

        const mime: Mime = blk: {
            if (content_type) |ct| {
                break :blk try Mime.parse(arena, ct);
            }
            break :blk Mime.sniff(try response.peek());
        } orelse .unknown;

        if (mime.isHTML()) {
            self.raw_data = null;
            try self.loadHTMLDoc(&response, mime.charset orelse "utf-8");
            try self.processHTMLDoc();
        } else {
            log.info("non-HTML document: {s}", .{content_type orelse "null"});
            var arr: std.ArrayListUnmanaged(u8) = .{};
            while (try response.next()) |data| {
                try arr.appendSlice(arena, try arena.dupe(u8, data));
            }
            // save the body into the page.
            self.raw_data = arr.items;
        }

        notification.dispatch(.page_navigated, &.{
            .url = &self.url,
            .timestamp = timestamp(),
        });
    }

    // https://html.spec.whatwg.org/#read-html
    fn loadHTMLDoc(self: *Page, reader: anytype, charset: []const u8) !void {
        log.debug("parse html with charset {s}", .{charset});

        const ccharset = try self.arena.dupeZ(u8, charset);

        const html_doc = try parser.documentHTMLParse(reader, ccharset);
        const doc = parser.documentHTMLToDocument(html_doc);

        // inject the URL to the document including the fragment.
        try parser.documentSetDocumentURI(doc, self.url.raw);

        // TODO set the referrer to the document.
        try self.window.replaceDocument(html_doc);
        self.window.setStorageShelf(
            try self.session.storage_shed.getOrPut(try self.origin(self.arena)),
        );
    }

    fn processHTMLDoc(self: *Page) !void {
        const html_doc = self.window.document;
        const doc = parser.documentHTMLToDocument(html_doc);

        const document_element = (try parser.documentGetDocumentElement(doc)) orelse return error.DocumentElementError;
        try parser.eventTargetAddEventListener(
            parser.toEventTarget(parser.Element, document_element),
            "click",
            &self.window_clicked_event_node,
            false,
        );

        // https://html.spec.whatwg.org/#read-html

        // browse the DOM tree to retrieve scripts
        // TODO execute the synchronous scripts during the HTL parsing.
        // TODO fetch the script resources concurrently but execute them in the
        // declaration order for synchronous ones.

        // async_scripts stores scripts which can be run asynchronously.
        // for now they are just run after the non-async one in order to
        // dispatch DOMContentLoaded the sooner as possible.
        var async_scripts: std.ArrayListUnmanaged(Script) = .{};

        // defer_scripts stores scripts which are meant to be deferred. For now
        // this doesn't have a huge impact, since normal scripts are parsed
        // after the document is loaded. But (a) we should fix that and (b)
        // this results in JavaScript being loaded in the same order as browsers
        // which can help debug issues (and might actually fix issues if websites
        // are expecting this execution order)
        var defer_scripts: std.ArrayListUnmanaged(Script) = .{};

        const root = parser.documentToNode(doc);
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = try walker.get_next(root, next) orelse break;

            // ignore non-elements nodes.
            if (try parser.nodeType(next.?) != .element) {
                continue;
            }

            const e = parser.nodeToElement(next.?);

            // ignore non-js script.
            const script = try Script.init(e) orelse continue;

            // TODO use fetchpriority
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#fetchpriority

            // > async
            // > For classic scripts, if the async attribute is present,
            // > then the classic script will be fetched in parallel to
            // > parsing and evaluated as soon as it is available.
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#async
            if (script.is_async) {
                try async_scripts.append(self.arena, script);
                continue;
            }

            if (script.is_defer) {
                try defer_scripts.append(self.arena, script);
                continue;
            }

            // TODO handle for attribute
            // TODO handle event attribute

            // > Scripts without async, defer or type="module"
            // > attributes, as well as inline scripts without the
            // > type="module" attribute, are fetched and executed
            // > immediately before the browser continues to parse the
            // > page.
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#notes
            try parser.documentHTMLSetCurrentScript(html_doc, @ptrCast(e));
            self.evalScript(&script) catch |err| log.warn("evaljs: {any}", .{err});
            try parser.documentHTMLSetCurrentScript(html_doc, null);
        }

        for (defer_scripts.items) |s| {
            try parser.documentHTMLSetCurrentScript(html_doc, @ptrCast(s.element));
            self.evalScript(&s) catch |err| log.warn("evaljs: {any}", .{err});
            try parser.documentHTMLSetCurrentScript(html_doc, null);
        }
        // dispatch DOMContentLoaded before the transition to "complete",
        // at the point where all subresources apart from async script elements
        // have loaded.
        // https://html.spec.whatwg.org/#reporting-document-loading-status
        try HTMLDocument.documentIsLoaded(html_doc, &self.state);

        // eval async scripts.
        for (async_scripts.items) |s| {
            try parser.documentHTMLSetCurrentScript(html_doc, @ptrCast(s.element));
            self.evalScript(&s) catch |err| log.warn("evaljs: {any}", .{err});
            try parser.documentHTMLSetCurrentScript(html_doc, null);
        }

        try HTMLDocument.documentIsComplete(html_doc, &self.state);

        // dispatch window.load event
        const loadevt = try parser.eventCreate();
        defer parser.eventDestroy(loadevt);

        try parser.eventInit(loadevt, "load", .{});
        _ = try parser.eventTargetDispatchEvent(
            parser.toEventTarget(Window, &self.window),
            loadevt,
        );
    }

    // evalScript evaluates the src in priority.
    // if no src is present, we evaluate the text source.
    // https://html.spec.whatwg.org/multipage/scripting.html#script-processing-model
    fn evalScript(self: *Page, script: *const Script) !void {
        const src = script.src orelse {
            // source is inline
            // TODO handle charset attribute
            if (try parser.nodeTextContent(parser.elementToNode(script.element))) |text| {
                try script.eval(self, text);
            }
            return;
        };

        self.current_script = script;
        defer self.current_script = null;

        log.debug("starting GET {s}", .{src});

        // https://html.spec.whatwg.org/multipage/webappapis.html#fetch-a-classic-script
        const body = (try self.fetchData(src, null)) orelse {
            // TODO If el's result is null, then fire an event named error at
            // el, and return
            return;
        };

        script.eval(self, body) catch |err| switch (err) {
            error.JsErr => {}, // nothing to do here.
            else => return err,
        };

        // TODO If el's from an external file is true, then fire an event
        // named load at el.
    }

    // fetchData returns the data corresponding to the src target.
    // It resolves src using the page's uri.
    // If a base path is given, src is resolved according to the base first.
    // the caller owns the returned string
    fn fetchData(self: *const Page, src: []const u8, base: ?[]const u8) !?[]const u8 {
        log.debug("starting fetch {s}", .{src});

        const arena = self.arena;

        // Handle data URIs.
        if (try DataURI.parse(arena, src)) |data_uri| {
            return data_uri.data;
        }

        var res_src = src;

        // if a base path is given, we resolve src using base.
        if (base) |_base| {
            res_src = try URL.stitch(arena, src, _base);
        }

        var origin_url = &self.url;
        const url = try origin_url.resolve(arena, res_src);

        var request = try self.newHTTPRequest(.GET, &url, .{
            .origin_uri = &origin_url.uri,
            .navigation = false,
        });
        defer request.deinit();

        var response = try request.sendSync(.{});
        var header = response.header;
        try self.session.cookie_jar.populateFromResponse(&url.uri, &header);

        log.info("fetch {any}: {d}", .{ url, header.status });

        if (header.status != 200) {
            return error.BadStatusCode;
        }

        var arr: std.ArrayListUnmanaged(u8) = .{};
        while (try response.next()) |data| {
            try arr.appendSlice(arena, try arena.dupe(u8, data));
        }

        // TODO check content-type

        // check no body
        if (arr.items.len == 0) {
            return null;
        }

        return arr.items;
    }

    fn newHTTPRequest(self: *const Page, method: http.Request.Method, url: *const URL, opts: storage.cookie.LookupOpts) !http.Request {
        // Don't use the state's request_factory here, since requests made by the
        // page (i.e. to load <scripts>) should not generate notifications.
        var request = try self.session.browser.http_client.request(method, &url.uri);
        errdefer request.deinit();

        var arr: std.ArrayListUnmanaged(u8) = .{};
        try self.state.cookie_jar.forRequest(&url.uri, arr.writer(self.arena), opts);

        if (arr.items.len > 0) {
            try request.addHeader("Cookie", arr.items, .{});
        }

        return request;
    }

    pub const MouseEvent = struct {
        x: i32,
        y: i32,
        type: Type,

        const Type = enum {
            pressed,
            released,
        };
    };

    pub fn mouseEvent(self: *Page, me: MouseEvent) !void {
        if (me.type != .pressed) {
            return;
        }

        const element = self.renderer.getElementAtPosition(me.x, me.y) orelse return;

        const event = try parser.mouseEventCreate();
        defer parser.mouseEventDestroy(event);
        try parser.mouseEventInit(event, "click", .{
            .bubbles = true,
            .cancelable = true,
            .x = me.x,
            .y = me.y,
        });
        _ = try parser.elementDispatchEvent(element, @ptrCast(event));
    }

    fn windowClicked(node: *parser.EventNode, event: *parser.Event) void {
        const self: *Page = @fieldParentPtr("window_clicked_event_node", node);
        self._windowClicked(event) catch |err| {
            log.err("window click handler: {}", .{err});
        };
    }

    fn _windowClicked(self: *Page, event: *parser.Event) !void {
        const target = (try parser.eventTarget(event)) orelse return;
        const node = parser.eventTargetToNode(target);
        const tag = (try parser.nodeHTMLGetTagType(node)) orelse return;
        switch (tag) {
            .a => {
                const element: *parser.Element = @ptrCast(node);
                const href = (try parser.elementGetAttribute(element, "href")) orelse return;

                // We cannot navigate immediately as navigating will delete the DOM tree, which holds this event's node.
                // As such we schedule the function to be called as soon as possible.
                // NOTE Using the page.arena assumes that the scheduling loop does use this object after invoking the callback
                // If that changes we may want to consider storing DelayedNavigation in the session instead.
                const arena = self.arena;
                const navi = try arena.create(DelayedNavigation);
                navi.* = .{
                    .session = self.session,
                    .href = try arena.dupe(u8, href),
                };
                _ = try self.state.loop.timeout(0, &navi.navigate_node);
            },
            else => {},
        }
    }

    const DelayedNavigation = struct {
        navigate_node: Loop.CallbackNode = .{ .func = DelayedNavigation.delay_navigate },
        session: *Session,
        href: []const u8,

        fn delay_navigate(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
            _ = repeat_delay;
            const self: *DelayedNavigation = @fieldParentPtr("navigate_node", node);
            self.session.pageNavigate(self.href) catch |err| {
                log.err("Delayed navigation error {}", .{err}); // TODO: should we trigger a specific event here?
            };
        }
    };

    const Script = struct {
        kind: Kind,
        is_async: bool,
        is_defer: bool,
        src: ?[]const u8,
        element: *parser.Element,
        // The javascript  to load after we successfully load the script
        onload: ?[]const u8,

        // The javascript to load if we have an error executing the script
        // For now, we ignore this, since we still have a lot of errors that we
        // shouldn't
        //onerror: ?[]const u8,

        const Kind = enum {
            module,
            javascript,
        };

        fn init(e: *parser.Element) !?Script {
            // ignore non-script tags
            const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(e)));
            if (tag != .script) {
                return null;
            }

            if (try parser.elementGetAttribute(e, "nomodule") != null) {
                // these scripts should only be loaded if we don't support modules
                // but since we do support modules, we can just skip them.
                return null;
            }

            const kind = parseKind(try parser.elementGetAttribute(e, "type")) orelse {
                return null;
            };

            return .{
                .kind = kind,
                .element = e,
                .src = try parser.elementGetAttribute(e, "src"),
                .onload = try parser.elementGetAttribute(e, "onload"),
                .is_async = try parser.elementGetAttribute(e, "async") != null,
                .is_defer = try parser.elementGetAttribute(e, "defer") != null,
            };
        }

        // > type
        // > Attribute is not set (default), an empty string, or a JavaScript MIME
        // > type indicates that the script is a "classic script", containing
        // > JavaScript code.
        // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#attribute_is_not_set_default_an_empty_string_or_a_javascript_mime_type
        fn parseKind(script_type_: ?[]const u8) ?Kind {
            const script_type = script_type_ orelse return .javascript;
            if (script_type.len == 0) {
                return .javascript;
            }

            if (std.mem.eql(u8, script_type, "application/javascript")) return .javascript;
            if (std.mem.eql(u8, script_type, "text/javascript")) return .javascript;
            if (std.mem.eql(u8, script_type, "module")) return .module;

            return null;
        }

        fn eval(self: *const Script, page: *Page, body: []const u8) !void {
            var try_catch: Env.TryCatch = undefined;
            try_catch.init(page.scope);
            defer try_catch.deinit();

            const src = self.src orelse "inline";
            const res = switch (self.kind) {
                .javascript => page.scope.exec(body, src),
                .module => blk: {
                    switch (try page.scope.module(body, src)) {
                        .value => |v| break :blk v,
                        .exception => |e| {
                            log.info("eval module {s}: {s}", .{
                                src,
                                try e.exception(page.arena),
                            });
                            return error.JsErr;
                        },
                    }
                },
            } catch {
                if (try try_catch.err(page.arena)) |msg| {
                    log.info("eval script {s}: {s}", .{ src, msg });
                }
                return error.JsErr;
            };
            _ = res;

            if (self.onload) |onload| {
                _ = page.scope.exec(onload, "script_on_load") catch {
                    if (try try_catch.err(page.arena)) |msg| {
                        log.info("eval script onload {s}: {s}", .{ src, msg });
                    }
                    return error.JsErr;
                };
            }
        }
    };
};

pub const NavigateReason = enum {
    anchor,
    address_bar,
};

pub const NavigateOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
};

fn timestamp() u32 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(ts.sec);
}

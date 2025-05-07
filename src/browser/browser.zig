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
const ArenaAllocator = std.heap.ArenaAllocator;

const Dump = @import("dump.zig");
const Mime = @import("mime.zig").Mime;
const DataURI = @import("datauri.zig").DataURI;
const parser = @import("netsurf.zig");

const Window = @import("html/window.zig").Window;
const Walker = @import("dom/walker.zig").WalkerDepthFirst;

const Env = @import("env.zig").Env;
const App = @import("../app.zig").App;
const Loop = @import("../runtime/loop.zig").Loop;

const URL = @import("../url.zig").URL;

const http = @import("../http/client.zig");
const storage = @import("storage/storage.zig");
const SessionState = @import("env.zig").SessionState;
const Notification = @import("../notification.zig").Notification;

const polyfill = @import("polyfill/polyfill.zig");

const log = std.log.scoped(.browser);

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
pub const Browser = struct {
    env: *Env,
    app: *App,
    session: ?Session,
    allocator: Allocator,
    http_client: *http.Client,
    page_arena: ArenaAllocator,
    notification: *Notification,

    pub fn init(app: *App) !Browser {
        const allocator = app.allocator;

        const env = try Env.init(allocator, .{});
        errdefer env.deinit();

        const notification = try Notification.init(allocator, app.notification);
        errdefer notification.deinit();

        return .{
            .app = app,
            .env = env,
            .session = null,
            .allocator = allocator,
            .notification = notification,
            .http_client = &app.http_client,
            .page_arena = ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Browser) void {
        self.closeSession();
        self.env.deinit();
        self.page_arena.deinit();
        self.notification.deinit();
    }

    pub fn newSession(self: *Browser) !*Session {
        self.closeSession();
        self.session = @as(Session, undefined);
        const session = &self.session.?;
        try Session.init(session, self);
        return session;
    }

    pub fn closeSession(self: *Browser) void {
        if (self.session) |*session| {
            session.deinit();
            self.session = null;
            if (self.app.config.gc_hints) {
                self.env.lowMemoryNotification();
            }
        }
    }

    pub fn runMicrotasks(self: *const Browser) void {
        return self.env.runMicrotasks();
    }
};

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
pub const Session = struct {
    browser: *Browser,

    // Used to create our Inspector and in the BrowserContext.
    arena: ArenaAllocator,

    executor: Env.Executor,
    storage_shed: storage.Shed,
    cookie_jar: storage.CookieJar,

    page: ?Page = null,

    fn init(self: *Session, browser: *Browser) !void {
        var executor = try browser.env.newExecutor();
        errdefer executor.deinit();

        const allocator = browser.app.allocator;
        self.* = .{
            .browser = browser,
            .executor = executor,
            .arena = ArenaAllocator.init(allocator),
            .storage_shed = storage.Shed.init(allocator),
            .cookie_jar = storage.CookieJar.init(allocator),
        };
    }

    fn deinit(self: *Session) void {
        if (self.page != null) {
            self.removePage();
        }
        self.arena.deinit();
        self.cookie_jar.deinit();
        self.storage_shed.deinit();
        self.executor.deinit();
    }

    // NOTE: the caller is not the owner of the returned value,
    // the pointer on Page is just returned as a convenience
    pub fn createPage(self: *Session) !*Page {
        std.debug.assert(self.page == null);

        const page_arena = &self.browser.page_arena;
        _ = page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });

        self.page = @as(Page, undefined);
        const page = &self.page.?;
        try Page.init(page, page_arena.allocator(), self);

        // start JS env
        log.debug("start new js scope", .{});
        // Inform CDP the main page has been created such that additional context for other Worlds can be created as well
        self.browser.notification.dispatch(.page_created, page);

        return page;
    }

    pub fn removePage(self: *Session) void {
        // Inform CDP the page is going to be removed, allowing other worlds to remove themselves before the main one
        self.browser.notification.dispatch(.page_remove, .{});

        std.debug.assert(self.page != null);
        // Reset all existing callbacks.
        self.browser.app.loop.reset();
        self.executor.endScope();
        self.page = null;

        // clear netsurf memory arena.
        parser.deinit();
    }

    pub fn currentPage(self: *Session) ?*Page {
        return &(self.page orelse return null);
    }

    fn pageNavigate(self: *Session, url_string: []const u8) !void {
        // currently, this is only called from the page, so let's hope
        // it isn't null!
        std.debug.assert(self.page != null);

        // can't use the page arena, because we're about to reset it
        // and don't want to use the session's arena, because that'll start to
        // look like a leak if we navigate from page to page a lot.
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const url = try self.page.?.url.resolve(fba.allocator(), url_string);

        self.removePage();
        var page = try self.createPage();
        return page.navigate(url, .{
            .reason = .anchor,
        });
    }
};

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

    doc: ?*parser.Document,

    // The URL of the page
    url: URL,

    raw_data: ?[]const u8,

    renderer: FlatRenderer,

    microtask_node: Loop.CallbackNode,

    window_clicked_event_node: parser.EventNode,

    scope: *Env.Scope,

    // current_script is the script currently evaluated by the page.
    // current_script could by fetch module to resolve module's url to fetch.
    current_script: ?*const Script = null,

    fn init(self: *Page, arena: Allocator, session: *Session) !void {
        const browser = session.browser;
        self.* = .{
            .window = .{},
            .arena = arena,
            .doc = null,
            .raw_data = null,
            .url = URL.empty,
            .session = session,
            .renderer = FlatRenderer.init(arena),
            .microtask_node = .{ .func = microtaskCallback },
            .window_clicked_event_node = .{ .func = windowClicked },
            .state = .{
                .arena = arena,
                .document = null,
                .url = &self.url,
                .renderer = &self.renderer,
                .loop = browser.app.loop,
                .cookie_jar = &session.cookie_jar,
                .http_client = browser.http_client,
            },
            .scope = try session.executor.startScope(&self.window, &self.state, self, true),
        };

        // load polyfills
        try polyfill.load(self.arena, self.scope);

        _ = try session.browser.app.loop.timeout(1 * std.time.ns_per_ms, &self.microtask_node);
    }

    fn microtaskCallback(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *Page = @fieldParentPtr("microtask_node", node);
        self.session.browser.runMicrotasks();
        repeat_delay.* = 1 * std.time.ns_per_ms;
    }

    // dump writes the page content into the given file.
    pub fn dump(self: *const Page, out: std.fs.File) !void {
        // if no HTML document pointer available, dump the data content only.
        if (self.doc == null) {
            // no data loaded, nothing to do.
            if (self.raw_data == null) return;
            return try out.writeAll(self.raw_data.?);
        }

        // if the page has a pointer to a document, dumps the HTML.
        try Dump.writeHTML(self.doc.?, out);
    }

    pub fn fetchModuleSource(ctx: *anyopaque, specifier: []const u8) ![]const u8 {
        const self: *Page = @ptrCast(@alignCast(ctx));

        log.debug("fetch module: specifier: {s}", .{specifier});
        return try self.fetchData(
            specifier,
            if (self.current_script) |s| s.src else null,
        );
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

        log.debug("starting GET {s}", .{request_url});

        // if the url is about:blank, nothing to do.
        if (std.mem.eql(u8, "about:blank", request_url.raw)) {
            return;
        }

        // we don't clone url, because we're going to replace self.url
        // later in this function, with the final request url (since we might
        // redirect)
        self.url = request_url;

        // load the data
        var request = try self.newHTTPRequest(.GET, &self.url, .{ .navigation = true });
        defer request.deinit();

        session.browser.notification.dispatch(.page_navigate, &.{
            .url = &self.url,
            .reason = opts.reason,
            .timestamp = timestamp(),
        });

        var response = try request.sendSync(.{});

        // would be different than self.url in the case of a redirect
        self.url = try URL.fromURI(arena, request.uri);

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
            try self.loadHTMLDoc(&response, mime.charset orelse "utf-8");
        } else {
            log.info("non-HTML document: {s}", .{content_type orelse "null"});
            var arr: std.ArrayListUnmanaged(u8) = .{};
            while (try response.next()) |data| {
                try arr.appendSlice(arena, try arena.dupe(u8, data));
            }
            // save the body into the page.
            self.raw_data = arr.items;
        }

        session.browser.notification.dispatch(.page_navigated, &.{
            .url = &self.url,
            .timestamp = timestamp(),
        });
    }

    // https://html.spec.whatwg.org/#read-html
    fn loadHTMLDoc(self: *Page, reader: anytype, charset: []const u8) !void {
        const arena = self.arena;

        // start netsurf memory arena.
        try parser.init();

        log.debug("parse html with charset {s}", .{charset});

        const ccharset = try arena.dupeZ(u8, charset);

        const html_doc = try parser.documentHTMLParse(reader, ccharset);
        const doc = parser.documentHTMLToDocument(html_doc);

        // save a document's pointer in the page.
        self.doc = doc;

        const document_element = (try parser.documentGetDocumentElement(doc)) orelse return error.DocumentElementError;
        try parser.eventTargetAddEventListener(
            parser.toEventTarget(parser.Element, document_element),
            "click",
            &self.window_clicked_event_node,
            false,
        );

        // TODO set document.readyState to interactive
        // https://html.spec.whatwg.org/#reporting-document-loading-status

        // inject the URL to the document including the fragment.
        try parser.documentSetDocumentURI(doc, self.url.raw);

        // TODO set the referrer to the document.
        try self.window.replaceDocument(html_doc);
        self.window.setStorageShelf(
            try self.session.storage_shed.getOrPut(try self.origin(self.arena)),
        );

        // https://html.spec.whatwg.org/#read-html

        // update the sessions state
        self.state.document = html_doc;

        // browse the DOM tree to retrieve scripts
        // TODO execute the synchronous scripts during the HTL parsing.
        // TODO fetch the script resources concurrently but execute them in the
        // declaration order for synchronous ones.

        // sasync stores scripts which can be run asynchronously.
        // for now they are just run after the non-async one in order to
        // dispatch DOMContentLoaded the sooner as possible.
        var sasync: std.ArrayListUnmanaged(Script) = .{};

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
            if (script.kind == .unknown) continue;

            // Ignore the defer attribute b/c we analyze all script
            // after the document has been parsed.
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#defer

            // TODO use fetchpriority
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#fetchpriority

            // > async
            // > For classic scripts, if the async attribute is present,
            // > then the classic script will be fetched in parallel to
            // > parsing and evaluated as soon as it is available.
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#async
            if (script.is_async) {
                try sasync.append(arena, script);
                continue;
            }

            // TODO handle for attribute
            // TODO handle event attribute

            // TODO defer
            // > This Boolean attribute is set to indicate to a browser
            // > that the script is meant to be executed after the
            // > document has been parsed, but before firing
            // > DOMContentLoaded.
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#defer
            // defer allow us to load a script w/o blocking the rest of
            // evaluations.

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

        // TODO wait for deferred scripts

        // dispatch DOMContentLoaded before the transition to "complete",
        // at the point where all subresources apart from async script elements
        // have loaded.
        // https://html.spec.whatwg.org/#reporting-document-loading-status
        const evt = try parser.eventCreate();
        defer parser.eventDestroy(evt);

        try parser.eventInit(evt, "DOMContentLoaded", .{ .bubbles = true, .cancelable = true });
        _ = try parser.eventTargetDispatchEvent(parser.toEventTarget(parser.DocumentHTML, html_doc), evt);

        // eval async scripts.
        for (sasync.items) |s| {
            try parser.documentHTMLSetCurrentScript(html_doc, @ptrCast(s.element));
            self.evalScript(&s) catch |err| log.warn("evaljs: {any}", .{err});
            try parser.documentHTMLSetCurrentScript(html_doc, null);
        }

        // TODO wait for async scripts

        // TODO set document.readyState to complete

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
    fn evalScript(self: *Page, s: *const Script) !void {
        self.current_script = s;
        defer self.current_script = null;

        // https://html.spec.whatwg.org/multipage/webappapis.html#fetch-a-classic-script
        const opt_src = try parser.elementGetAttribute(s.element, "src");
        if (opt_src) |src| {
            log.debug("starting GET {s}", .{src});

            self.fetchScript(s) catch |err| {
                switch (err) {
                    FetchError.BadStatusCode => return err,

                    // TODO If el's result is null, then fire an event named error at
                    // el, and return.
                    FetchError.NoBody => return,

                    FetchError.JsErr => {}, // nothing to do here.
                    else => return err,
                }
            };

            // TODO If el's from an external file is true, then fire an event
            // named load at el.

            return;
        }

        // TODO handle charset attribute
        const opt_text = try parser.nodeTextContent(parser.elementToNode(s.element));
        if (opt_text) |text| {
            try s.eval(self, text);
            return;
        }

        // nothing has been loaded.
        // TODO If el's result is null, then fire an event named error at
        // el, and return.
    }

    const FetchError = error{
        BadStatusCode,
        NoBody,
        JsErr,
    };

    // fetchData returns the data corresponding to the src target.
    // It resolves src using the page's uri.
    // If a base path is given, src is resolved according to the base first.
    // the caller owns the returned string
    fn fetchData(self: *const Page, src: []const u8, base: ?[]const u8) ![]const u8 {
        log.debug("starting fetch {s}", .{src});

        const arena = self.arena;

        // Handle data URIs.
        if (try DataURI.parse(arena, src)) |data_uri| {
            return data_uri.data;
        }

        var res_src = src;

        // if a base path is given, we resolve src using base.
        if (base) |_base| {
            const dir = std.fs.path.dirname(_base);
            if (dir) |_dir| {
                res_src = try std.fs.path.resolve(arena, &.{ _dir, src });
            }
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
            return FetchError.BadStatusCode;
        }

        var arr: std.ArrayListUnmanaged(u8) = .{};
        while (try response.next()) |data| {
            try arr.appendSlice(arena, try arena.dupe(u8, data));
        }

        // TODO check content-type

        // check no body
        if (arr.items.len == 0) {
            return FetchError.NoBody;
        }

        return arr.items;
    }

    fn fetchScript(self: *Page, s: *const Script) !void {
        const body = try self.fetchData(s.src, null);
        try s.eval(self, body);
    }

    fn newHTTPRequest(self: *const Page, method: http.Request.Method, url: *const URL, opts: storage.cookie.LookupOpts) !http.Request {
        var request = try self.state.http_client.request(method, &url.uri);
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
        if (try parser.nodeType(node) != .element) {
            return;
        }

        const html_element: *parser.ElementHTML = @ptrCast(node);
        switch (try parser.elementHTMLGetTagType(html_element)) {
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
                log.err("Delayed navigation error {}", .{err});
            };
        }
    };

    const Script = struct {
        element: *parser.Element,
        kind: Kind,
        is_async: bool,

        src: []const u8,

        const Kind = enum {
            unknown,
            javascript,
            module,
        };

        fn init(e: *parser.Element) !?Script {
            // ignore non-script tags
            const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(e)));
            if (tag != .script) return null;

            return .{
                .element = e,
                .kind = parseKind(try parser.elementGetAttribute(e, "type")),
                .is_async = try parser.elementGetAttribute(e, "async") != null,
                .src = try parser.elementGetAttribute(e, "src") orelse "inline",
            };
        }

        // > type
        // > Attribute is not set (default), an empty string, or a JavaScript MIME
        // > type indicates that the script is a "classic script", containing
        // > JavaScript code.
        // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#attribute_is_not_set_default_an_empty_string_or_a_javascript_mime_type
        fn parseKind(stype: ?[]const u8) Kind {
            if (stype == null or stype.?.len == 0) return .javascript;
            if (std.mem.eql(u8, stype.?, "application/javascript")) return .javascript;
            if (std.mem.eql(u8, stype.?, "text/javascript")) return .javascript;
            if (std.mem.eql(u8, stype.?, "module")) return .module;

            return .unknown;
        }

        fn eval(self: Script, page: *Page, body: []const u8) !void {
            var try_catch: Env.TryCatch = undefined;
            try_catch.init(page.scope);
            defer try_catch.deinit();

            const res = switch (self.kind) {
                .unknown => return error.UnknownScript,
                .javascript => page.scope.exec(body, self.src),
                .module => page.scope.module(body, self.src),
            } catch {
                if (try try_catch.err(page.arena)) |msg| {
                    log.info("eval script {s}: {s}", .{ self.src, msg });
                }
                return FetchError.JsErr;
            };

            if (builtin.mode == .Debug) {
                const msg = try res.toString(page.arena);
                log.debug("eval script {s}: {s}", .{ self.src, msg });
            }
        }
    };
};

pub const NavigateReason = enum {
    anchor,
    address_bar,
};

const NavigateOpts = struct {
    reason: NavigateReason = .address_bar,
};

// provide very poor abstration to the rest of the code. In theory, we can change
// the FlatRenderer to a different implementation, and it'll all just work.
pub const Renderer = FlatRenderer;

// This "renderer" positions elements in a single row in an unspecified order.
// The important thing is that elements have a consistent position/index within
// that row, which can be turned into a rectangle.
const FlatRenderer = struct {
    allocator: Allocator,

    // key is a @ptrFromInt of the element
    // value is the index position
    positions: std.AutoHashMapUnmanaged(u64, u32),

    // given an index, get the element
    elements: std.ArrayListUnmanaged(u64),

    const Element = @import("dom/element.zig").Element;

    // we expect allocator to be an arena
    pub fn init(allocator: Allocator) FlatRenderer {
        return .{
            .elements = .{},
            .positions = .{},
            .allocator = allocator,
        };
    }

    pub fn getRect(self: *FlatRenderer, e: *parser.Element) !Element.DOMRect {
        var elements = &self.elements;
        const gop = try self.positions.getOrPut(self.allocator, @intFromPtr(e));
        var x: u32 = gop.value_ptr.*;
        if (gop.found_existing == false) {
            x = @intCast(elements.items.len);
            try elements.append(self.allocator, @intFromPtr(e));
            gop.value_ptr.* = x;
        }

        return .{
            .x = @floatFromInt(x),
            .y = 0.0,
            .width = 1.0,
            .height = 1.0,
        };
    }

    pub fn boundingRect(self: *const FlatRenderer) Element.DOMRect {
        return .{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.width()),
            .height = @floatFromInt(self.height()),
        };
    }

    pub fn width(self: *const FlatRenderer) u32 {
        return @max(@as(u32, @intCast(self.elements.items.len)), 1); // At least 1 pixel even if empty
    }

    pub fn height(_: *const FlatRenderer) u32 {
        return 1;
    }

    pub fn getElementAtPosition(self: *const FlatRenderer, x: i32, y: i32) ?*parser.Element {
        if (y != 0 or x < 0) {
            return null;
        }

        const elements = self.elements.items;
        return if (x < elements.len) @ptrFromInt(elements[@intCast(x)]) else null;
    }
};

fn timestamp() u32 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(ts.sec);
}

const testing = @import("../testing.zig");
test "Browser" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    // this will crash if ICU isn't properly configured / ininitialized
    try runner.testCases(&.{
        .{ "new Intl.DateTimeFormat()", "[object Intl.DateTimeFormat]" },
    }, .{});
}

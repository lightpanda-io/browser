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
const State = @import("State.zig");
const Env = @import("env.zig").Env;
const Mime = @import("mime.zig").Mime;
const DataURI = @import("datauri.zig").DataURI;
const Session = @import("session.zig").Session;
const Renderer = @import("renderer.zig").Renderer;
const Window = @import("html/window.zig").Window;
const Walker = @import("dom/walker.zig").WalkerDepthFirst;
const Loop = @import("../runtime/loop.zig").Loop;
const HTMLDocument = @import("html/document.zig").HTMLDocument;
const RequestFactory = @import("../http/client.zig").RequestFactory;

const URL = @import("../url.zig").URL;

const log = @import("../log.zig");
const parser = @import("netsurf.zig");
const http = @import("../http/client.zig");
const storage = @import("storage/storage.zig");

const polyfill = @import("polyfill/polyfill.zig");

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
// The page handle all its memory in an arena allocator. The arena is reseted
// when end() is called.
pub const Page = struct {
    // Our event loop
    loop: *Loop,

    cookie_jar: *storage.CookieJar,

    // Pre-configured http/cilent.zig used to make HTTP requests.
    request_factory: RequestFactory,

    session: *Session,

    // An arena with a lifetime for the entire duration of the page
    arena: Allocator,

    // Managed by the JS runtime, meant to have a much shorter life than the
    // above arena. It should only be used by WebAPIs.
    call_arena: Allocator,

    // Serves are the root object of our JavaScript environment
    window: Window,

    // The URL of the page
    url: URL,

    // If the body of the main page isn't HTML, we capture its raw bytes here
    // (currently, this is only useful in fetch mode with the --dump option)
    raw_data: ?[]const u8,

    renderer: Renderer,

    // run v8 micro tasks
    microtask_node: Loop.CallbackNode,
    // run v8 pump message loop and idle tasks
    messageloop_node: Loop.CallbackNode,

    keydown_event_node: parser.EventNode,
    window_clicked_event_node: parser.EventNode,

    // Our JavaScript context for this specific page. This is what we use to
    // execute any JavaScript
    main_context: *Env.JsContext,

    // indicates intention to navigate to another page on the next loop execution.
    delayed_navigation: bool = false,

    state_pool: *std.heap.MemoryPool(State),

    polyfill_loader: polyfill.Loader = .{},

    pub fn init(self: *Page, arena: Allocator, session: *Session) !void {
        const browser = session.browser;
        self.* = .{
            .window = try Window.create(null, null),
            .arena = arena,
            .raw_data = null,
            .url = URL.empty,
            .session = session,
            .call_arena = undefined,
            .loop = browser.app.loop,
            .renderer = Renderer.init(arena),
            .state_pool = &browser.state_pool,
            .cookie_jar = &session.cookie_jar,
            .microtask_node = .{ .func = microtaskCallback },
            .messageloop_node = .{ .func = messageLoopCallback },
            .keydown_event_node = .{ .func = keydownCallback },
            .window_clicked_event_node = .{ .func = windowClicked },
            .request_factory = browser.http_client.requestFactory(.{
                .notification = browser.notification,
            }),
            .main_context = undefined,
        };
        self.main_context = try session.executor.createJsContext(&self.window, self, self, true, Env.GlobalMissingCallback.init(&self.polyfill_loader));
        try polyfill.preload(self.arena, self.main_context);

        // message loop must run only non-test env
        if (comptime !builtin.is_test) {
            _ = try session.browser.app.loop.timeout(1 * std.time.ns_per_ms, &self.microtask_node);
            _ = try session.browser.app.loop.timeout(100 * std.time.ns_per_ms, &self.messageloop_node);
        }
    }

    fn microtaskCallback(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *Page = @fieldParentPtr("microtask_node", node);
        self.session.browser.runMicrotasks();
        repeat_delay.* = 1 * std.time.ns_per_ms;
    }

    fn messageLoopCallback(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *Page = @fieldParentPtr("messageloop_node", node);
        self.session.browser.runMessageLoop();
        repeat_delay.* = 100 * std.time.ns_per_ms;
    }

    // dump writes the page content into the given file.
    pub fn dump(self: *const Page, opts: Dump.Opts, out: std.fs.File) !void {
        if (self.raw_data) |raw_data| {
            // raw_data was set if the document was not HTML, dump the data content only.
            return try out.writeAll(raw_data);
        }

        // if the page has a pointer to a document, dumps the HTML.
        const doc = parser.documentHTMLToDocument(self.window.document);
        try Dump.writeHTML(doc, opts, out);
    }

    pub fn fetchModuleSource(ctx: *anyopaque, src: []const u8) !?[]const u8 {
        const self: *Page = @ptrCast(@alignCast(ctx));
        return self.fetchData("module", src);
    }

    pub fn wait(self: *Page, wait_ns: usize) !void {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(self.main_context);
        defer try_catch.deinit();

        try self.session.browser.app.loop.run(wait_ns);

        if (try_catch.hasCaught() == false) {
            log.debug(.browser, "page wait complete", .{});
            return;
        }

        const msg = (try try_catch.err(self.arena)) orelse "unknown";
        log.err(.browser, "page wait error", .{ .err = msg });
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

        log.debug(.http, "navigate", .{
            .url = request_url,
            .method = opts.method,
            .reason = opts.reason,
            .body = opts.body != null,
        });

        // if the url is about:blank, nothing to do.
        if (std.mem.eql(u8, "about:blank", request_url.raw)) {
            var fbs = std.io.fixedBufferStream("");
            try self.loadHTMLDoc(fbs.reader(), "utf-8");
            // We do not processHTMLDoc here as we know we don't have any scripts
            // This assumption may be false when CDP Page.addScriptToEvaluateOnNewDocument is implemented
            try HTMLDocument.documentIsComplete(self.window.document, self);
            return;
        }

        // we don't clone url, because we're going to replace self.url
        // later in this function, with the final request url (since we might
        // redirect)
        self.url = request_url;

        {
            // block exists to limit the lifetime of the request, which holds
            // onto a connection
            var request = try self.newHTTPRequest(opts.method, &self.url, .{ .navigation = true, .is_http = true });
            defer request.deinit();

            request.body = opts.body;
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

            const content_type = header.get("content-type");

            const mime: Mime = blk: {
                if (content_type) |ct| {
                    break :blk try Mime.parse(arena, ct);
                }
                break :blk Mime.sniff(try response.peek());
            } orelse .unknown;

            log.info(.http, "navigation", .{
                .status = header.status,
                .content_type = content_type,
                .charset = mime.charset,
                .url = request_url,
                .method = opts.method,
                .reason = opts.reason,
            });

            if (mime.isHTML()) {
                // the page is an HTML, load it as it.
                try self.loadHTMLDoc(&response, mime.charset orelse "utf-8");
            } else {
                // the page isn't an HTML
                var arr: std.ArrayListUnmanaged(u8) = .{};
                while (try response.next()) |data| {
                    try arr.appendSlice(arena, try arena.dupe(u8, data));
                }
                // save the body into the page.
                self.raw_data = arr.items;

                // construct a pseudo HTML containing the response body.
                var buf: std.ArrayListUnmanaged(u8) = .{};

                switch (mime.content_type) {
                    .application_json, .text_plain, .text_javascript, .text_css => {
                        try buf.appendSlice(arena, "<html><head><meta charset=\"utf-8\"></head><body><pre>");
                        try buf.appendSlice(arena, self.raw_data.?);
                        try buf.appendSlice(arena, "</pre></body></html>\n");
                    },
                    // In other cases, we prefer to not integrate the content into the HTML document page iself.
                    else => {},
                }
                var fbs = std.io.fixedBufferStream(buf.items);
                try self.loadHTMLDoc(fbs.reader(), mime.charset orelse "utf-8");
            }
        }

        try self.processHTMLDoc();

        notification.dispatch(.page_navigated, &.{
            .url = &self.url,
            .timestamp = timestamp(),
        });
        log.debug(.http, "navigation complete", .{
            .url = request_url,
        });
    }

    // https://html.spec.whatwg.org/#read-html
    pub fn loadHTMLDoc(self: *Page, reader: anytype, charset: []const u8) !void {
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

        // we want to be notified of any dynamically added script tags
        // so that we can load the script
        parser.documentSetScriptAddedCallback(doc, self, scriptAddedCallback);

        const document_element = (try parser.documentGetDocumentElement(doc)) orelse return error.DocumentElementError;
        _ = try parser.eventTargetAddEventListener(
            parser.toEventTarget(parser.Element, document_element),
            "click",
            &self.window_clicked_event_node,
            false,
        );
        _ = try parser.eventTargetAddEventListener(
            parser.toEventTarget(parser.Element, document_element),
            "keydown",
            &self.keydown_event_node,
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

            const current = next.?;

            const e = parser.nodeToElement(current);
            const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(e)));

            if (tag != .script) {
                // ignore non-js script.
                continue;
            }

            const script = try Script.init(e, null) orelse continue;

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
            if (self.evalScript(&script) == false) {
                return;
            }
        }

        for (defer_scripts.items) |*script| {
            if (self.evalScript(script) == false) {
                return;
            }
        }
        // dispatch DOMContentLoaded before the transition to "complete",
        // at the point where all subresources apart from async script elements
        // have loaded.
        // https://html.spec.whatwg.org/#reporting-document-loading-status
        try HTMLDocument.documentIsLoaded(html_doc, self);

        // eval async scripts.
        for (async_scripts.items) |*script| {
            if (self.evalScript(script) == false) {
                return;
            }
        }

        try HTMLDocument.documentIsComplete(html_doc, self);

        // dispatch window.load event
        const loadevt = try parser.eventCreate();
        defer parser.eventDestroy(loadevt);

        log.debug(.script_event, "dispatch event", .{ .type = "load", .source = "page" });
        try parser.eventInit(loadevt, "load", .{});
        _ = try parser.eventTargetDispatchEvent(
            parser.toEventTarget(Window, &self.window),
            loadevt,
        );
    }

    fn evalScript(self: *Page, script: *const Script) bool {
        self.tryEvalScript(script) catch |err| switch (err) {
            error.JsErr => {}, // already been logged with detail
            error.Terminated => return false,
            else => log.err(.js, "eval script error", .{ .err = err, .src = script.src }),
        };
        return true;
    }

    // evalScript evaluates the src in priority.
    // if no src is present, we evaluate the text source.
    // https://html.spec.whatwg.org/multipage/scripting.html#script-processing-model
    fn tryEvalScript(self: *Page, script: *const Script) !void {
        if (try script.alreadyProcessed()) {
            return;
        }

        try script.markAsProcessed();

        const html_doc = self.window.document;
        try parser.documentHTMLSetCurrentScript(html_doc, @ptrCast(script.element));

        defer parser.documentHTMLSetCurrentScript(html_doc, null) catch |err| {
            log.err(.browser, "clear document script", .{ .err = err });
        };

        const src = script.src orelse {
            // source is inline
            // TODO handle charset attribute
            const script_source = try parser.nodeTextContent(parser.elementToNode(script.element)) orelse return;
            return script.eval(self, script_source);
        };

        // https://html.spec.whatwg.org/multipage/webappapis.html#fetch-a-classic-script
        const script_source = (try self.fetchData("script", src)) orelse {
            // TODO If el's result is null, then fire an event named error at
            // el, and return
            return;
        };
        return script.eval(self, script_source);

        // TODO If el's from an external file is true, then fire an event
        // named load at el.
    }

    // fetchData returns the data corresponding to the src target.
    // It resolves src using the page's uri.
    // If a base path is given, src is resolved according to the base first.
    // the caller owns the returned string
    fn fetchData(
        self: *const Page,
        comptime reason: []const u8,
        src: []const u8,
    ) !?[]const u8 {
        const arena = self.arena;

        // Handle data URIs.
        if (try DataURI.parse(arena, src)) |data_uri| {
            return data_uri.data;
        }

        var origin_url = &self.url;
        const url = try origin_url.resolve(arena, src);

        var status_code: u16 = 0;
        log.debug(.http, "fetching script", .{
            .url = url,
            .src = src,
            .reason = reason,
        });

        errdefer |err| log.err(.http, "fetch error", .{
            .err = err,
            .url = url,
            .reason = reason,
            .status = status_code,
        });

        var request = try self.newHTTPRequest(.GET, &url, .{
            .origin_uri = &origin_url.uri,
            .navigation = false,
            .is_http = true,
        });
        defer request.deinit();

        var response = try request.sendSync(.{});
        var header = response.header;
        try self.session.cookie_jar.populateFromResponse(&url.uri, &header);

        status_code = header.status;
        if (status_code < 200 or status_code > 299) {
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

        log.info(.http, "fetch complete", .{
            .url = url,
            .reason = reason,
            .status = status_code,
            .content_length = arr.items.len,
        });
        return arr.items;
    }

    fn newHTTPRequest(self: *const Page, method: http.Request.Method, url: *const URL, opts: storage.cookie.LookupOpts) !*http.Request {
        // Don't use the state's request_factory here, since requests made by the
        // page (i.e. to load <scripts>) should not generate notifications.
        var request = try self.session.browser.http_client.request(method, &url.uri);
        errdefer request.deinit();

        var arr: std.ArrayListUnmanaged(u8) = .{};
        try self.cookie_jar.forRequest(&url.uri, arr.writer(self.arena), opts);

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
            log.err(.browser, "click handler error", .{ .err = err });
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
                try self.navigateFromWebAPI(href, .{});
            },
            .input => {
                const element: *parser.Element = @ptrCast(node);
                const input_type = try parser.inputGetType(@ptrCast(element));
                if (std.ascii.eqlIgnoreCase(input_type, "submit")) {
                    return self.elementSubmitForm(element);
                }
            },
            .button => {
                const element: *parser.Element = @ptrCast(node);
                const button_type = try parser.buttonGetType(@ptrCast(element));
                if (std.ascii.eqlIgnoreCase(button_type, "submit")) {
                    return self.elementSubmitForm(element);
                }
                if (std.ascii.eqlIgnoreCase(button_type, "reset")) {
                    if (try self.formForElement(element)) |form| {
                        return parser.formElementReset(form);
                    }
                }
            },
            else => {},
        }
    }

    pub const KeyboardEvent = struct {
        type: Type,
        key: []const u8,
        code: []const u8,
        alt: bool,
        ctrl: bool,
        meta: bool,
        shift: bool,

        const Type = enum {
            keydown,
        };
    };

    pub fn keyboardEvent(self: *Page, kbe: KeyboardEvent) !void {
        if (kbe.type != .keydown) {
            return;
        }

        const Document = @import("dom/document.zig").Document;
        const element = (try Document.getActiveElement(@ptrCast(self.window.document), self)) orelse return;

        const event = try parser.keyboardEventCreate();
        defer parser.keyboardEventDestroy(event);
        try parser.keyboardEventInit(event, "keydown", .{
            .bubbles = true,
            .cancelable = true,
            .key = kbe.key,
            .code = kbe.code,
            .alt = kbe.alt,
            .ctrl = kbe.ctrl,
            .meta = kbe.meta,
            .shift = kbe.shift,
        });
        _ = try parser.elementDispatchEvent(element, @ptrCast(event));
    }

    fn keydownCallback(node: *parser.EventNode, event: *parser.Event) void {
        const self: *Page = @fieldParentPtr("keydown_event_node", node);
        self._keydownCallback(event) catch |err| {
            log.err(.browser, "keydown handler error", .{ .err = err });
        };
    }

    fn _keydownCallback(self: *Page, event: *parser.Event) !void {
        const target = (try parser.eventTarget(event)) orelse return;
        const node = parser.eventTargetToNode(target);
        const tag = (try parser.nodeHTMLGetTagType(node)) orelse return;

        const kbe: *parser.KeyboardEvent = @ptrCast(event);
        var new_key = try parser.keyboardEventGetKey(kbe);
        if (std.mem.eql(u8, new_key, "Dead")) {
            return;
        }

        switch (tag) {
            .input => {
                const element: *parser.Element = @ptrCast(node);
                const input_type = try parser.inputGetType(@ptrCast(element));
                if (std.mem.eql(u8, input_type, "text")) {
                    if (std.mem.eql(u8, new_key, "Enter")) {
                        const form = (try self.formForElement(element)) orelse return;
                        return self.submitForm(@ptrCast(form), null);
                    }

                    const value = try parser.inputGetValue(@ptrCast(element));
                    const new_value = try std.mem.concat(self.arena, u8, &.{ value, new_key });
                    try parser.inputSetValue(@ptrCast(element), new_value);
                }
            },
            .textarea => {
                const value = try parser.textareaGetValue(@ptrCast(node));
                if (std.mem.eql(u8, new_key, "Enter")) {
                    new_key = "\n";
                }
                const new_value = try std.mem.concat(self.arena, u8, &.{ value, new_key });
                try parser.textareaSetValue(@ptrCast(node), new_value);
            },
            else => {},
        }
    }

    // We cannot navigate immediately as navigating will delete the DOM tree,
    // which holds this event's node.
    // As such we schedule the function to be called as soon as possible.
    // The page.arena is safe to use here, but the transfer_arena exists
    // specifically for this type of lifetime.
    pub fn navigateFromWebAPI(self: *Page, url: []const u8, opts: NavigateOpts) !void {
        log.debug(.browser, "delayed navigation", .{
            .url = url,
            .reason = opts.reason,
        });
        self.delayed_navigation = true;

        const session = self.session;
        const arena = session.transfer_arena;
        const navi = try arena.create(DelayedNavigation);
        navi.* = .{
            .opts = opts,
            .session = session,
            .url = try self.url.resolve(arena, url),
        };

        // In v8, this throws an exception which JS code cannot catch.
        session.executor.terminateExecution();
        _ = try self.loop.timeout(0, &navi.navigate_node);
    }

    pub fn getOrCreateNodeState(self: *Page, node: *parser.Node) !*State {
        if (self.getNodeState(node)) |wrap| {
            return wrap;
        }

        const state = try self.state_pool.create();
        state.* = .{};

        parser.nodeSetEmbedderData(node, state);
        return state;
    }

    pub fn getNodeState(_: *const Page, node: *parser.Node) ?*State {
        if (parser.nodeGetEmbedderData(node)) |state| {
            return @alignCast(@ptrCast(state));
        }
        return null;
    }

    pub fn submitForm(self: *Page, form: *parser.Form, submitter: ?*parser.ElementHTML) !void {
        const FormData = @import("xhr/form_data.zig").FormData;

        const transfer_arena = self.session.transfer_arena;
        var form_data = try FormData.fromForm(form, submitter, self);

        const encoding = try parser.elementGetAttribute(@alignCast(@ptrCast(form)), "enctype");

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try form_data.write(encoding, buf.writer(transfer_arena));

        const method = try parser.elementGetAttribute(@alignCast(@ptrCast(form)), "method") orelse "";
        var action = try parser.elementGetAttribute(@alignCast(@ptrCast(form)), "action") orelse self.url.raw;

        var opts = NavigateOpts{
            .reason = .form,
        };
        if (std.ascii.eqlIgnoreCase(method, "post")) {
            opts.method = .POST;
            opts.body = buf.items;
        } else {
            action = try URL.concatQueryString(transfer_arena, action, buf.items);
        }
        try self.navigateFromWebAPI(action, opts);
    }

    pub fn isNodeAttached(self: *const Page, node: *parser.Node) !bool {
        const root = parser.documentToNode(parser.documentHTMLToDocument(self.window.document));
        return root == try parser.nodeGetRootNode(node);
    }

    fn elementSubmitForm(self: *Page, element: *parser.Element) !void {
        const form = (try self.formForElement(element)) orelse return;
        return self.submitForm(@ptrCast(form), @ptrCast(element));
    }

    fn formForElement(self: *Page, element: *parser.Element) !?*parser.Form {
        if (try parser.elementGetAttribute(element, "disabled") != null) {
            return null;
        }

        if (try parser.elementGetAttribute(element, "form")) |form_id| {
            const document = parser.documentHTMLToDocument(self.window.document);
            const form_element = try parser.documentGetElementById(document, form_id) orelse return null;
            if (try parser.elementHTMLGetTagType(@ptrCast(form_element)) == .form) {
                return @ptrCast(form_element);
            }
            return null;
        }

        const Element = @import("dom/element.zig").Element;
        const form = (try Element._closest(element, "form", self)) orelse return null;
        return @ptrCast(form);
    }

    pub fn stackTrace(self: *Page) !?[]const u8 {
        if (comptime builtin.mode == .Debug) {
            return self.main_context.stackTrace();
        }
        return null;
    }
};

const DelayedNavigation = struct {
    url: URL,
    session: *Session,
    opts: NavigateOpts,
    initial: bool = true,
    navigate_node: Loop.CallbackNode = .{ .func = delayNavigate },

    // Navigation is blocking, which is problem because it can seize up
    // the loop and deadlock. We can only safely try to navigate to a
    // new page when we're sure there's at least 1 free slot in the
    // http client. We handle this in two phases:
    //
    // In the first phase, when self.initial == true, we'll shutdown the page
    // and create a new one. The shutdown is important, because it resets the
    // loop ctx_id and removes the JsContext. Removing the context calls our XHR
    // destructors which aborts requests. This is necessary to make sure our
    // [blocking] navigate won't block.
    //
    // In the 2nd phase, we wait until there's a free http slot so that our
    // navigate definetly won't block (which could deadlock the system if there
    // are still pending async requests, which we've seen happen, even after
    // an abort).
    fn delayNavigate(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *DelayedNavigation = @fieldParentPtr("navigate_node", node);

        const session = self.session;
        const initial = self.initial;

        if (initial) {
            // Prior to schedule this task, we terminated excution to stop
            // the running script. If we don't resume it before doing a shutdown
            // we'll get an error.
            session.executor.resumeExecution();

            session.removePage();
            _ = session.createPage() catch |err| {
                log.err(.browser, "delayed navigation page error", .{
                    .err = err,
                    .url = self.url,
                });
                return;
            };
            self.initial = false;
        }

        if (session.browser.http_client.freeSlotCount() == 0) {
            log.debug(.browser, "delayed navigate waiting", .{});
            const delay = 0 * std.time.ns_per_ms;

            // If this isn't the initial check, we can safely re-use the timer
            // to check again.
            if (initial == false) {
                repeat_delay.* = delay;
                return;
            }

            // However, if this _is_ the initial check, we called
            // session.removePage above, and that reset the loop ctx_id.
            // We can't re-use this timer, because it has the previous ctx_id.
            // We can create a new timeout though, and that'll get the new ctx_id.
            //
            // Page has to be not-null here because we called createPage above.
            _ = session.page.?.loop.timeout(delay, &self.navigate_node) catch |err| {
                log.err(.browser, "delayed navigation loop err", .{ .err = err });
            };
            return;
        }

        const page = session.currentPage() orelse return;
        defer if (!page.delayed_navigation) {
            // If, while loading the page, we intend to navigate to another
            // page, then we need to keep the transfer_arena around, as this
            // sub-navigation is probably using it.
            _ = session.browser.transfer_arena.reset(.{ .retain_with_limit = 64 * 1024 });
        };

        return page.navigate(self.url, self.opts) catch |err| {
            log.err(.browser, "delayed navigation error", .{ .err = err, .url = self.url });
        };
    }
};

const Script = struct {
    kind: Kind,
    is_async: bool,
    is_defer: bool,
    src: ?[]const u8,
    element: *parser.Element,
    // The javascript to load after we successfully load the script
    onload: ?Callback,
    onerror: ?Callback,

    // The javascript to load if we have an error executing the script
    // For now, we ignore this, since we still have a lot of errors that we
    // shouldn't
    //onerror: ?[]const u8,

    const Kind = enum {
        module,
        javascript,
    };

    const Callback = union(enum) {
        string: []const u8,
        function: Env.Function,
    };

    fn init(e: *parser.Element, page_: ?*const Page) !?Script {
        if (try parser.elementGetAttribute(e, "nomodule") != null) {
            // these scripts should only be loaded if we don't support modules
            // but since we do support modules, we can just skip them.
            return null;
        }

        const kind = parseKind(try parser.elementGetAttribute(e, "type")) orelse {
            return null;
        };

        var onload: ?Callback = null;
        var onerror: ?Callback = null;

        if (page_) |page| {
            // If we're given the page, then it means the script is dynamic
            // and we need to load the onload and onerror function (if there are
            // any) from our WebAPI.
            // This page == null is an optimization which isn't technically
            // correct, as a static script could have a dynamic onload/onerror
            // attached to it. But this seems quite unlikely and it does help
            // optimize loading scripts, of which there can be hundreds for a
            // page.
            if (page.getNodeState(@ptrCast(e))) |se| {
                if (se.onload) |function| {
                    onload = .{ .function = function };
                }
                if (se.onerror) |function| {
                    onerror = .{ .function = function };
                }
            }
        } else {
            if (try parser.elementGetAttribute(e, "onload")) |string| {
                onload = .{ .string = string };
            }
            if (try parser.elementGetAttribute(e, "onerror")) |string| {
                onerror = .{ .string = string };
            }
        }

        return .{
            .kind = kind,
            .element = e,
            .onload = onload,
            .onerror = onerror,
            .src = try parser.elementGetAttribute(e, "src"),
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

        if (std.ascii.eqlIgnoreCase(script_type, "application/javascript")) return .javascript;
        if (std.ascii.eqlIgnoreCase(script_type, "text/javascript")) return .javascript;
        if (std.ascii.eqlIgnoreCase(script_type, "module")) return .module;

        return null;
    }

    // If a script tag gets dynamically created and added to the dom:
    //    document.getElementsByTagName('head')[0].appendChild(script)
    // that script tag will immediately get executed by our scriptAddedCallback.
    // However, if the location where the script tag is inserted happens to be
    // below where processHTMLDoc curently is, then we'll re-run that same script
    // again in processHTMLDoc. This flag is used to let us know if a specific
    // <script> has already been processed.
    fn alreadyProcessed(self: *const Script) !bool {
        return parser.scriptGetProcessed(@ptrCast(self.element));
    }

    fn markAsProcessed(self: *const Script) !void {
        return parser.scriptSetProcessed(@ptrCast(self.element), true);
    }

    fn eval(self: *const Script, page: *Page, body: []const u8) !void {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(page.main_context);
        defer try_catch.deinit();

        const src: []const u8 = blk: {
            const s = self.src orelse break :blk page.url.raw;
            break :blk try URL.stitch(page.arena, s, page.url.raw, .{ .alloc = .if_needed });
        };

        // if self.src is null, then this is an inline script, and it should
        // not be cached.
        const cacheable = self.src != null;

        log.debug(.browser, "executing script", .{
            .src = src,
            .kind = self.kind,
            .cacheable = cacheable,
        });

        const failed = blk: {
            switch (self.kind) {
                .javascript => _ = page.main_context.eval(body, src) catch break :blk true,
                // We don't care about waiting for the evaluation here.
                .module => _ = page.main_context.module(body, src, cacheable) catch break :blk true,
            }
            break :blk false;
        };

        if (failed) {
            if (page.delayed_navigation) {
                return error.Terminated;
            }

            if (try try_catch.err(page.arena)) |msg| {
                log.warn(.user_script, "eval script", .{
                    .src = src,
                    .err = msg,
                    .cacheable = cacheable,
                });
            }

            try self.executeCallback("onerror", page);
            return error.JsErr;
        }

        try self.executeCallback("onload", page);
    }

    fn executeCallback(self: *const Script, comptime typ: []const u8, page: *Page) !void {
        const callback = @field(self, typ) orelse return;
        switch (callback) {
            .string => |str| {
                var try_catch: Env.TryCatch = undefined;
                try_catch.init(page.main_context);
                defer try_catch.deinit();
                _ = page.main_context.exec(str, typ) catch {
                    if (try try_catch.err(page.arena)) |msg| {
                        log.warn(.user_script, "script callback", .{
                            .src = self.src,
                            .err = msg,
                            .type = typ,
                            .@"inline" = true,
                        });
                    }
                };
            },
            .function => |f| {
                const Event = @import("events/event.zig").Event;
                const loadevt = try parser.eventCreate();
                defer parser.eventDestroy(loadevt);

                var result: Env.Function.Result = undefined;
                f.tryCall(void, .{try Event.toInterface(loadevt)}, &result) catch {
                    log.warn(.user_script, "script callback", .{
                        .src = self.src,
                        .type = typ,
                        .err = result.exception,
                        .stack = result.stack,
                        .@"inline" = false,
                    });
                };
            },
        }
    }
};

pub const NavigateReason = enum {
    anchor,
    address_bar,
    form,
    script,
};

pub const NavigateOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: http.Request.Method = .GET,
    body: ?[]const u8 = null,
};

fn timestamp() u32 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(ts.sec);
}

// A callback from libdom whenever a script tag is added to the DOM.
// element is guaranteed to be a script element.
// The script tag might not have a src. It might be any attribute, like
// `nomodule`, `defer` and `async`. `Script.init` will return null on `nomodule`
// so that's handled. And because we're only executing the inline <script> tags
// after the document is loaded, it's ok to execute any async and defer scripts
// immediately.
pub export fn scriptAddedCallback(ctx: ?*anyopaque, element: ?*parser.Element) callconv(.C) void {
    const self: *Page = @alignCast(@ptrCast(ctx.?));
    if (self.delayed_navigation) {
        // if we're planning on navigating to another page, don't run this script
        return;
    }

    var script = Script.init(element.?, self) catch |err| {
        log.warn(.browser, "script added init error", .{ .err = err });
        return;
    } orelse return;

    _ = self.evalScript(&script);
}

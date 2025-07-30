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
const ScriptManager = @import("ScriptManager.zig");
const HTMLDocument = @import("html/document.zig").HTMLDocument;

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
    // @newhttp
    // request_factory: RequestFactory,

    session: *Session,

    // An arena with a lifetime for the entire duration of the page
    arena: Allocator,

    // Managed by the JS runtime, meant to have a much shorter life than the
    // above arena. It should only be used by WebAPIs.
    call_arena: Allocator,

    // Serves as the root object of our JavaScript environment
    window: Window,

    // The URL of the page
    url: URL,

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

    http_client: *http.Client,
    script_manager: ScriptManager,

    mode: Mode,

    loaded: bool = false,

    const Mode = union(enum) {
        pre: void,
        err: anyerror,
        parsed: void,
        html: parser.Parser,
        raw: std.ArrayListUnmanaged(u8),
        raw_done: []const u8,
    };

    pub fn init(self: *Page, arena: Allocator, session: *Session) !void {
        const browser = session.browser;
        const script_manager = ScriptManager.init(browser.app, self);

        self.* = .{
            .url = URL.empty,
            .mode = .{ .pre = {} },
            .window = try Window.create(null, null),
            .arena = arena,
            .session = session,
            .call_arena = undefined,
            .loop = browser.app.loop,
            .renderer = Renderer.init(arena),
            .state_pool = &browser.state_pool,
            .cookie_jar = &session.cookie_jar,
            .script_manager = script_manager,
            .http_client = browser.http_client,
            .microtask_node = .{ .func = microtaskCallback },
            .messageloop_node = .{ .func = messageLoopCallback },
            .keydown_event_node = .{ .func = keydownCallback },
            .window_clicked_event_node = .{ .func = windowClicked },
            // @newhttp
            // .request_factory = browser.http_client.requestFactory(.{
            //     .notification = browser.notification,
            // }),
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

    pub fn deinit(self: *Page) void {
        self.script_manager.deinit();
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

    pub const DumpOpts = struct {
        // set to include element shadowroots in the dump
        page: ?*const Page = null,
        with_base: bool = false,
        exclude_scripts: bool = false,
    };

    // dump writes the page content into the given file.
    pub fn dump(self: *const Page, opts: DumpOpts, out: std.fs.File) !void {
        switch (self.mode) {
            .pre => return error.PageNotLoaded,
            .raw => |buf| {
                // maybe page.wait timed-out, print what we have
                log.warn(.http, "incomplete load", .{ .mode = "raw" });
                return out.writeAll(buf.items);
            },
            .raw_done => |data| return out.writeAll(data),
            .html => {
                // maybe page.wait timed-out, print what we have
                log.warn(.http, "incomplete load", .{ .mode = "html" });
                // processed below, along with .html
            },
            .parsed => {
                // processed below, along with .html
            },
            .err => |err| return err,
        }

        const doc = parser.documentHTMLToDocument(self.window.document);

        // if the base si requested, add the base's node in the document's headers.
        if (opts.with_base) {
            try self.addDOMTreeBase();
        }

        try Dump.writeHTML(doc, .{
            .page = opts.page,
            .exclude_scripts = opts.exclude_scripts,
        }, out);
    }

    // addDOMTreeBase modifies the page's document to add a <base> tag after
    // <head>.
    // If <head> is missing, the function returns silently.
    fn addDOMTreeBase(self: *const Page) !void {
        const doc = parser.documentHTMLToDocument(self.window.document);
        std.debug.assert(doc.is_html);

        // find <head> tag
        const list = try parser.documentGetElementsByTagName(doc, "head");
        const head = try parser.nodeListItem(list, 0) orelse return;

        const base = try parser.documentCreateElement(doc, "base");
        try parser.elementSetAttribute(base, "href", self.url.raw);

        const Node = @import("dom/node.zig").Node;
        try Node.prepend(head, &[_]Node.NodeOrText{.{ .node = parser.elementToNode(base) }});
    }

    pub fn fetchModuleSource(ctx: *anyopaque, src: []const u8) !?[]const u8 {
        _ = ctx;
        _ = src;
        // @newhttp
        return error.NewHTTP;
        // const self: *Page = @ptrCast(@alignCast(ctx));
        // return self.fetchData("module", src);
    }

    pub fn wait(self: *Page, wait_sec: usize) !void {
        switch (self.mode) {
            .pre, .html, .raw, .parsed => {
                // The HTML page was parsed. We now either have JS scripts to
                // download, or timeouts to execute, or both.

                const cutoff = timestamp() + wait_sec;

                var try_catch: Env.TryCatch = undefined;
                try_catch.init(self.main_context);
                defer try_catch.deinit();

                var http_client = self.http_client;
                var loop = self.session.browser.app.loop;

                // @newhttp Not sure about the timing / the order / any of this.
                // I think I want to remove the loop. Implement our own timeouts
                // and switch the CDP server to blocking. For now, just try this.`
                while (timestamp() < cutoff) {
                    const has_pending_timeouts = loop.hasPendingTimeout();
                    if (http_client.active > 0) {
                        try http_client.tick(10); // 10ms
                    } else if (self.loaded and self.loaded and !has_pending_timeouts) {
                        // we have no active HTTP requests, and no timeouts pending
                        return;
                    }

                    if (!has_pending_timeouts) {
                        continue;
                    }

                    // 10ms
                    try loop.run(std.time.ns_per_ms * 10);

                    if (try_catch.hasCaught()) {
                        const msg = (try try_catch.err(self.arena)) orelse "unknown";
                        log.err(.browser, "page wait error", .{ .err = msg });
                        return error.JsError;
                    }
                }
            },
            .err => |err| return err,
            .raw_done => return,
        }
    }

    pub fn origin(self: *const Page, arena: Allocator) ![]const u8 {
        var arr: std.ArrayListUnmanaged(u8) = .{};
        try self.url.origin(arr.writer(arena));
        return arr.items;
    }

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    pub fn navigate(self: *Page, request_url: []const u8, opts: NavigateOpts) !void {
        log.debug(.http, "navigate", .{
            .url = request_url,
            .method = opts.method,
            .reason = opts.reason,
            .body = opts.body != null,
        });

        // if the url is about:blank, nothing to do.
        if (std.mem.eql(u8, "about:blank", request_url)) {
            const html_doc = try parser.documentHTMLParseFromStr("");
            try self.setDocument(html_doc);

            // We do not processHTMLDoc here as we know we don't have any scripts
            // This assumption may be false when CDP Page.addScriptToEvaluateOnNewDocument is implemented
            try HTMLDocument.documentIsComplete(self.window.document, self);
            return;
        }

        const owned_url = try self.arena.dupeZ(u8, request_url);

        try self.http_client.request(.{
            .ctx = self,
            .url = owned_url,
            .method = opts.method,
            .header_done_callback = pageHeaderCallback,
            .data_callback = pageDataCallback,
            .done_callback = pageDoneCallback,
            .error_callback = pageErrorCallback,
        });

        self.session.browser.notification.dispatch(.page_navigate, &.{
            .opts = opts,
            .url = owned_url,
            .timestamp = timestamp(),
        });
    }

    pub fn documentIsLoaded(self: *Page) void {
        HTMLDocument.documentIsLoaded(self.window.document, self) catch |err| {
            log.err(.browser, "document is loaded", .{ .err = err });
        };
    }

    pub fn documentIsComplete(self: *Page) void {
        std.debug.assert(self.loaded == false);

        self.loaded = true;
        self._documentIsComplete() catch |err| {
            log.err(.browser, "document is complete", .{ .err = err });
        };

        self.session.browser.notification.dispatch(.page_navigated, &.{
            .url = self.url.raw,
            .timestamp = timestamp(),
        });
    }
    fn _documentIsComplete(self: *Page) !void {
        try HTMLDocument.documentIsComplete(self.window.document, self);

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

    fn pageHeaderCallback(transfer: *http.Transfer) !void {
        var self: *Page = @alignCast(@ptrCast(transfer.ctx));

        // would be different than self.url in the case of a redirect
        const header = &transfer.response_header.?;
        const owned_url = try self.arena.dupe(u8, std.mem.span(header.url));
        self.url = try URL.parse(owned_url, null);

        log.debug(.http, "navigate header", .{
            .url = self.url,
            .status = header.status,
            .content_type = header.contentType(),
        });
    }

    fn pageDataCallback(transfer: *http.Transfer, data: []const u8) !void {
        var self: *Page = @alignCast(@ptrCast(transfer.ctx));

        if (self.mode == .pre) {
            // we lazily do this, because we might need the first chunk of data
            // to sniff the content type
            const mime: Mime = blk: {
                if (transfer.response_header.?.contentType()) |ct| {
                    break :blk try Mime.parse(ct);
                }
                break :blk Mime.sniff(data);
            } orelse .unknown;

            const is_html = mime.isHTML();
            log.debug(.http, "navigate first chunk", .{ .html = is_html, .len = data.len });

            if (is_html) {
                self.mode = .{ .html = try parser.Parser.init(mime.charset orelse "UTF-8") };
            } else {
                self.mode = .{ .raw = .{} };
            }
        }

        switch (self.mode) {
            .html => |*p| try p.process(data),
            .raw => |*buf| try buf.appendSlice(self.arena, data),
            .pre => unreachable,
            .parsed => unreachable,
            .err => unreachable,
            .raw_done => unreachable,
        }
    }

    fn pageDoneCallback(transfer: *http.Transfer) !void {
        log.debug(.http, "navigate done", .{});

        var self: *Page = @alignCast(@ptrCast(transfer.ctx));

        switch (self.mode) {
            .raw => |buf| self.mode = .{ .raw_done = buf.items },
            .html => |*p| {
                const html_doc = p.html_doc;
                p.deinit(); // don't need the parser anymore

                self.mode = .{ .parsed = {} };

                try self.setDocument(html_doc);
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

                const root = parser.documentToNode(doc);
                const walker = Walker{};
                var next: ?*parser.Node = null;
                while (try walker.get_next(root, next)) |n| {
                    next = n;
                    const node = next.?;
                    const tag = (try parser.nodeHTMLGetTagType(node)) orelse continue;
                    if (tag != .script) {
                        // ignore non-js script.
                        continue;
                    }
                    try self.script_manager.addFromElement(@ptrCast(node));
                }

                self.script_manager.staticScriptsDone();
            },
            else => unreachable,
        }
    }

    fn pageErrorCallback(transfer: *http.Transfer, err: anyerror) void {
        log.err(.http, "navigate failed", .{ .err = err });
        var self: *Page = @alignCast(@ptrCast(transfer.ctx));
        switch (self.mode) {
            .html => |*p| p.deinit(), // don't need the parser anymore
            else => {},
        }
        self.mode = .{ .err = err };
    }

    // extracted because this sis called from tests to set things up.
    pub fn setDocument(self: *Page, html_doc: *parser.DocumentHTML) !void {
        const doc = parser.documentHTMLToDocument(html_doc);
        try parser.documentSetDocumentURI(doc, self.url.raw);

        // TODO set the referrer to the document.
        try self.window.replaceDocument(html_doc);
        self.window.setStorageShelf(
            try self.session.storage_shed.getOrPut(try self.origin(self.arena)),
        );
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
            if (try parser.elementTag(@ptrCast(form_element)) == .form) {
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
        _ = node;
        _ = repeat_delay;
        // @newhttp
        // const self: *DelayedNavigation = @fieldParentPtr("navigate_node", node);

        // const session = self.session;
        // const initial = self.initial;

        // if (initial) {
        //     // Prior to schedule this task, we terminated excution to stop
        //     // the running script. If we don't resume it before doing a shutdown
        //     // we'll get an error.
        //     session.executor.resumeExecution();

        //     session.removePage();
        //     _ = session.createPage() catch |err| {
        //         log.err(.browser, "delayed navigation page error", .{
        //             .err = err,
        //             .url = self.url,
        //         });
        //         return;
        //     };
        //     self.initial = false;
        // }

        // if (session.browser.http_client.freeSlotCount() == 0) {
        //     log.debug(.browser, "delayed navigate waiting", .{});
        //     const delay = 0 * std.time.ns_per_ms;

        //     // If this isn't the initial check, we can safely re-use the timer
        //     // to check again.
        //     if (initial == false) {
        //         repeat_delay.* = delay;
        //         return;
        //     }

        //     // However, if this _is_ the initial check, we called
        //     // session.removePage above, and that reset the loop ctx_id.
        //     // We can't re-use this timer, because it has the previous ctx_id.
        //     // We can create a new timeout though, and that'll get the new ctx_id.
        //     //
        //     // Page has to be not-null here because we called createPage above.
        //     _ = session.page.?.loop.timeout(delay, &self.navigate_node) catch |err| {
        //         log.err(.browser, "delayed navigation loop err", .{ .err = err });
        //     };
        //     return;
        // }

        // const page = session.currentPage() orelse return;
        // defer if (!page.delayed_navigation) {
        //     // If, while loading the page, we intend to navigate to another
        //     // page, then we need to keep the transfer_arena around, as this
        //     // sub-navigation is probably using it.
        //     _ = session.browser.transfer_arena.reset(.{ .retain_with_limit = 64 * 1024 });
        // };

        // return page.navigate(self.url, self.opts) catch |err| {
        //     log.err(.browser, "delayed navigation error", .{ .err = err, .url = self.url });
        // };
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
    method: http.Method = .GET,
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
    _ = ctx;
    _ = element;
    // @newhttp
    // const self: *Page = @alignCast(@ptrCast(ctx.?));
    // if (self.delayed_navigation) {
    //     // if we're planning on navigating to another page, don't run this script
    //     return;
    // }

    // var script = Script.init(element.?, self) catch |err| {
    //     log.warn(.browser, "script added init error", .{ .err = err });
    //     return;
    // } orelse return;

    // _ = self.evalScript(&script);
}

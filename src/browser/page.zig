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
const Session = @import("session.zig").Session;
const Renderer = @import("renderer.zig").Renderer;
const Window = @import("html/window.zig").Window;
const Walker = @import("dom/walker.zig").WalkerDepthFirst;
const Scheduler = @import("Scheduler.zig");
const Http = @import("../http/Http.zig");
const ScriptManager = @import("ScriptManager.zig");
const HTMLDocument = @import("html/document.zig").HTMLDocument;

const URL = @import("../url.zig").URL;

const log = @import("../log.zig");
const parser = @import("netsurf.zig");
const storage = @import("storage/storage.zig");

const polyfill = @import("polyfill/polyfill.zig");

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
// The page handle all its memory in an arena allocator. The arena is reseted
// when end() is called.

pub const Page = struct {
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

    keydown_event_node: parser.EventNode,
    window_clicked_event_node: parser.EventNode,

    // Our JavaScript context for this specific page. This is what we use to
    // execute any JavaScript
    main_context: *Env.JsContext,

    // indicates intention to navigate to another page on the next loop execution.
    delayed_navigation: bool = false,

    state_pool: *std.heap.MemoryPool(State),

    polyfill_loader: polyfill.Loader = .{},

    scheduler: Scheduler,
    http_client: *Http.Client,
    script_manager: ScriptManager,

    mode: Mode,

    load_state: LoadState = .parsing,

    // Page.wait balances waiting for resources / tasks and producing an output.
    // Up until a timeout, Page.wait will always wait for inflight or pending
    // HTTP requests, via the Http.Client.active counter. However, intercepted
    // requests (via CDP, but it could be anything), aren't considered "active"
    // connection. So it's possible that we have intercepted requests (which are
    // pending on some driver to continue/abort) while Http.Client.active == 0.
    // This boolean exists to supplment Http.Client.active and inform Page.wait
    // of pending connections.
    request_intercepted: bool = false,

    const Mode = union(enum) {
        pre: void,
        err: anyerror,
        parsed: void,
        html: parser.Parser,
        text: parser.Parser,
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

    pub fn init(self: *Page, arena: Allocator, session: *Session) !void {
        const browser = session.browser;
        const script_manager = ScriptManager.init(browser, self);

        self.* = .{
            .url = URL.empty,
            .mode = .{ .pre = {} },
            .window = try Window.create(null, null),
            .arena = arena,
            .session = session,
            .call_arena = undefined,
            .renderer = Renderer.init(arena),
            .state_pool = &browser.state_pool,
            .cookie_jar = &session.cookie_jar,
            .script_manager = script_manager,
            .http_client = browser.http_client,
            .scheduler = Scheduler.init(arena),
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

        try self.scheduler.add(self, runMicrotasks, 5, .{ .name = "page.microtasks" });
        // message loop must run only non-test env
        if (comptime !builtin.is_test) {
            try self.scheduler.add(self, runMessageLoop, 5, .{ .name = "page.messageLoop" });
        }
    }

    pub fn deinit(self: *Page) void {
        self.script_manager.shutdown = true;

        self.http_client.abort();
        self.script_manager.deinit();
    }

    fn reset(self: *Page) void {
        self.scheduler.reset();
        self.http_client.abort();
        self.script_manager.reset();

        self.load_state = .parsing;
        self.mode = .{ .pre = {} };
        _ = self.session.browser.page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });
    }

    fn runMicrotasks(ctx: *anyopaque) ?u32 {
        const self: *Page = @alignCast(@ptrCast(ctx));
        self.session.browser.runMicrotasks();
        return 5;
    }

    fn runMessageLoop(ctx: *anyopaque) ?u32 {
        const self: *Page = @alignCast(@ptrCast(ctx));
        self.session.browser.runMessageLoop();
        return 100;
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
            .text => {
                // returns the <pre> element from the HTML
                const doc = parser.documentHTMLToDocument(self.window.document);
                const list = try parser.documentGetElementsByTagName(doc, "pre");
                const pre = try parser.nodeListItem(list, 0) orelse return error.InvalidHTML;
                const walker = Walker{};
                var next: ?*parser.Node = null;
                while (true) {
                    next = try walker.get_next(pre, next) orelse break;
                    const v = try parser.nodeTextContent(next.?) orelse return;
                    try out.writeAll(v);
                }
                return;
            },
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

    pub fn fetchModuleSource(ctx: *anyopaque, src: [:0]const u8) !ScriptManager.BlockingResult {
        const self: *Page = @ptrCast(@alignCast(ctx));
        return self.script_manager.blockingGet(src);
    }

    pub fn wait(self: *Page, wait_sec: usize) void {
        self._wait(wait_sec) catch |err| switch (err) {
            error.JsError => {}, // already logged (with hopefully more context)
            else => {
                // There may be errors from the http/client or ScriptManager
                // that we should not treat as an error like this. Will need
                // to run this through more real-world sites and see if we need
                // to expand the switch (err) to have more customized logs for
                // specific messages.
                log.err(.browser, "page wait", .{ .err = err });
            },
        };
    }

    fn _wait(self: *Page, wait_sec: usize) !void {
        var ms_remaining = wait_sec * 1000;
        var timer = try std.time.Timer.start();

        var try_catch: Env.TryCatch = undefined;
        try_catch.init(self.main_context);
        defer try_catch.deinit();

        var scheduler = &self.scheduler;
        var http_client = self.http_client;

        // for debugging
        // defer self.printWaitAnalysis();

        while (true) {
            SW: switch (self.mode) {
                .pre, .raw, .text => {
                    if (self.request_intercepted) {
                        // the page request was intercepted.

                        // there shouldn't be any active requests;
                        std.debug.assert(http_client.active == 0);

                        // nothing we can do for this, need to kick the can up
                        // the chain and wait for activity (e.g. a CDP message)
                        // to unblock this.
                        return;
                    }

                    // The main page hasn't started/finished navigating.
                    // There's no JS to run, and no reason to run the scheduler.
                    if (http_client.active == 0) {
                        // haven't started navigating, I guess.
                        return;
                    }

                    // There should only be 1 active http transfer, the main page
                    try http_client.tick(ms_remaining);
                },
                .html, .parsed => {
                    // The HTML page was parsed. We now either have JS scripts to
                    // download, or timeouts to execute, or both.

                    // scheduler.run could trigger new http transfers, so do not
                    // store http_client.active BEFORE this call and then use
                    // it AFTER.
                    const ms_to_next_task = try scheduler.runHighPriority();

                    if (try_catch.hasCaught()) {
                        const msg = (try try_catch.err(self.arena)) orelse "unknown";
                        log.warn(.user_script, "page wait", .{ .err = msg, .src = "scheduler" });
                        return error.JsError;
                    }

                    if (http_client.active == 0) {
                        if (ms_to_next_task) |ms| {
                            // There are no HTTP transfers, so there's no point calling
                            // http_client.tick.
                            // TODO: should we just force-run the scheduler??

                            if (ms > ms_remaining) {
                                // we'd wait to long, might as well exit early.
                                return;
                            }
                            _ = try scheduler.runLowPriority();

                            // We must use a u64 here b/c ms is a u32 and the
                            // conversion to ns can generate an integer
                            // overflow.
                            const _ms: u64 = @intCast(ms);

                            std.time.sleep(std.time.ns_per_ms * _ms);
                            break :SW;
                        }

                        // We have no active http transfer and no pending
                        // schedule tasks. We're done
                        return;
                    }

                    _ = try scheduler.runLowPriority();

                    const request_intercepted = self.request_intercepted;

                    // We want to prioritize processing intercepted requests
                    // because, the sooner they get unblocked, the sooner we
                    // can start the HTTP request. But we still want to advanced
                    // existing HTTP requests, if possible. So, if we have
                    // intercepted requests, we'll still look at existing HTTP
                    // requests, but we won't block waiting for more data.
                    const ms_to_wait =
                        if (request_intercepted) 0

                        // But if we have no intercepted requests, we'll wait
                        // for as long as we can for data to our existing
                        // inflight requests
                        else @min(ms_remaining, ms_to_next_task orelse 1000);

                    try http_client.tick(ms_to_wait);

                    if (request_intercepted) {
                        // Again, proritizing intercepted requests. Exit this
                        // loop so that our caller can hopefully resolve them
                        // (i.e. continue or abort them);
                        return;
                    }
                },
                .err => |err| {
                    self.mode = .{ .raw_done = @errorName(err) };
                    return err;
                },
                .raw_done => return,
            }

            const ms_elapsed = timer.lap() / 1_000_000;
            if (ms_elapsed >= ms_remaining) {
                return;
            }
            ms_remaining -= ms_elapsed;
        }
    }

    fn printWaitAnalysis(self: *Page) void {
        std.debug.print("mode: {s}\n", .{@tagName(std.meta.activeTag(self.mode))});
        std.debug.print("load: {s}\n", .{@tagName(self.load_state)});
        {
            std.debug.print("\nactive requests: {d}\n", .{self.http_client.active});
            var n_ = self.http_client.handles.in_use.first;
            while (n_) |n| {
                const transfer = Http.Transfer.fromEasy(n.data.conn.easy) catch |err| {
                    std.debug.print(" - failed to load transfer: {any}\n", .{err});
                    break;
                };
                std.debug.print(" - {s}\n", .{transfer});
                n_ = n.next;
            }
        }

        {
            std.debug.print("\nqueued requests: {d}\n", .{self.http_client.queue.len});
            var n_ = self.http_client.queue.first;
            while (n_) |n| {
                std.debug.print(" - {s}\n", .{n.data.url});
                n_ = n.next;
            }
        }

        {
            std.debug.print("\nscripts: {d}\n", .{self.script_manager.scripts.len});
            var n_ = self.script_manager.scripts.first;
            while (n_) |n| {
                std.debug.print(" - {s} complete: {any}\n", .{ n.data.script.url, n.data.complete });
                n_ = n.next;
            }
        }

        {
            std.debug.print("\ndeferreds: {d}\n", .{self.script_manager.deferreds.len});
            var n_ = self.script_manager.deferreds.first;
            while (n_) |n| {
                std.debug.print(" - {s} complete: {any}\n", .{ n.data.script.url, n.data.complete });
                n_ = n.next;
            }
        }

        const now = std.time.milliTimestamp();
        {
            std.debug.print("\nasyncs: {d}\n", .{self.script_manager.asyncs.len});
            var n_ = self.script_manager.asyncs.first;
            while (n_) |n| {
                std.debug.print(" - {s} complete: {any}\n", .{ n.data.script.url, n.data.complete });
                n_ = n.next;
            }
        }

        {
            std.debug.print("\nprimary schedule: {d}\n", .{self.scheduler.primary.count()});
            var it = self.scheduler.primary.iterator();
            while (it.next()) |task| {
                std.debug.print(" - {s} schedule: {d}ms\n", .{ task.name, task.ms - now });
            }
        }

        {
            std.debug.print("\nsecondary schedule: {d}\n", .{self.scheduler.secondary.count()});
            var it = self.scheduler.secondary.iterator();
            while (it.next()) |task| {
                std.debug.print(" - {s} schedule: {d}ms\n", .{ task.name, task.ms - now });
            }
        }
    }

    pub fn origin(self: *const Page, arena: Allocator) ![]const u8 {
        var arr: std.ArrayListUnmanaged(u8) = .{};
        try self.url.origin(arr.writer(arena));
        return arr.items;
    }

    const RequestCookieOpts = struct {
        is_http: bool = true,
        is_navigation: bool = false,
    };
    pub fn requestCookie(self: *const Page, opts: RequestCookieOpts) Http.Client.RequestCookie {
        return .{
            .jar = self.cookie_jar,
            .origin = &self.url.uri,
            .is_http = opts.is_http,
            .is_navigation = opts.is_navigation,
        };
    }

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    pub fn navigate(self: *Page, request_url: []const u8, opts: NavigateOpts) !void {
        if (self.mode != .pre) {
            // it's possible for navigate to be called multiple times on the
            // same page (via CDP). We want to reset the page between each call.
            self.reset();
        }

        log.info(.http, "navigate", .{
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
        self.url = try URL.parse(owned_url, null);

        var headers = try Http.Headers.init();
        if (opts.header) |hdr| try headers.add(hdr);
        try self.requestCookie(.{ .is_navigation = true }).headersForRequest(self.arena, owned_url, &headers);

        self.http_client.request(.{
            .ctx = self,
            .url = owned_url,
            .method = opts.method,
            .headers = headers,
            .body = opts.body,
            .cookie_jar = self.cookie_jar,
            .resource_type = .document,
            .header_callback = pageHeaderDoneCallback,
            .data_callback = pageDataCallback,
            .done_callback = pageDoneCallback,
            .error_callback = pageErrorCallback,
        }) catch |err| {
            log.err(.http, "navigate request", .{ .url = owned_url, .err = err });
            return err;
        };

        self.session.browser.notification.dispatch(.page_navigate, &.{
            .opts = opts,
            .url = owned_url,
            .timestamp = timestamp(),
        });
    }

    pub fn setCurrentScript(self: *Page, script: ?*parser.Script) !void {
        const html_doc = self.window.document;
        try parser.documentHTMLSetCurrentScript(html_doc, script);
    }

    pub fn documentIsLoaded(self: *Page) void {
        if (self.load_state != .parsing) {
            // Ideally, documentIsLoaded would only be called once, but if a
            // script is dynamically added from an async script after
            // documentIsLoaded is already called, then ScriptManager will call
            // it again.
            return;
        }

        self.load_state = .load;
        HTMLDocument.documentIsLoaded(self.window.document, self) catch |err| {
            log.err(.browser, "document is loaded", .{ .err = err });
        };
    }

    pub fn documentIsComplete(self: *Page) void {
        if (self.load_state == .complete) {
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
        if (self.load_state == .parsing) {
            self.documentIsLoaded();
        }

        self.load_state = .complete;
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

    fn pageHeaderDoneCallback(transfer: *Http.Transfer) !void {
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

    fn pageDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
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

            log.debug(.http, "navigate first chunk", .{ .content_type = mime.content_type, .len = data.len });

            self.mode = switch (mime.content_type) {
                .text_html => .{ .html = try parser.Parser.init(mime.charset orelse "UTF-8") },

                .application_json,
                .text_javascript,
                .text_css,
                .text_plain,
                => blk: {
                    var p = try parser.Parser.init(mime.charset orelse "UTF-8");
                    try p.process("<html><head><meta charset=\"utf-8\"></head><body><pre>");
                    break :blk .{ .text = p };
                },

                else => .{ .raw = .{} },
            };
        }

        switch (self.mode) {
            .html => |*p| try p.process(data),
            .text => |*p| {
                // we have to escape the data...
                var v = data;
                while (v.len > 0) {
                    const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '<', '>' }) orelse {
                        try p.process(v);
                        return;
                    };
                    try p.process(v[0..index]);
                    switch (v[index]) {
                        '<' => try p.process("&lt;"),
                        '>' => try p.process("&gt;"),
                        else => unreachable,
                    }
                    v = v[index + 1 ..];
                }
            },
            .raw => |*buf| try buf.appendSlice(self.arena, data),
            .pre => unreachable,
            .parsed => unreachable,
            .err => unreachable,
            .raw_done => unreachable,
        }
    }

    fn pageDoneCallback(ctx: *anyopaque) !void {
        log.debug(.http, "navigate done", .{});

        var self: *Page = @alignCast(@ptrCast(ctx));
        self.clearTransferArena();

        switch (self.mode) {
            .raw => |buf| {
                self.mode = .{ .raw_done = buf.items };
                self.documentIsComplete();
            },
            .text => |*p| {
                try p.process("</pre></body></html>");
                const html_doc = p.html_doc;
                p.deinit(); // don't need the parser anymore
                try self.setDocument(html_doc);
                self.documentIsComplete();
            },
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
                    const e = parser.nodeToElement(node);
                    const tag = try parser.elementTag(e);
                    if (tag != .script) {
                        // ignore non-js script.
                        continue;
                    }
                    try self.script_manager.addFromElement(@ptrCast(node));
                }

                self.script_manager.staticScriptsDone();

                if (self.script_manager.isDone()) {
                    // No scripts, or just inline scripts that were already processed
                    // we need to trigger this ourselves
                    self.documentIsComplete();
                }
            },
            else => unreachable,
        }
    }

    fn pageErrorCallback(ctx: *anyopaque, err: anyerror) void {
        log.err(.http, "navigate failed", .{ .err = err });

        var self: *Page = @alignCast(@ptrCast(ctx));
        self.clearTransferArena();

        switch (self.mode) {
            .html, .text => |*p| p.deinit(), // don't need the parser anymore
            else => {},
        }
        self.mode = .{ .err = err };
    }

    // The transfer arena is useful and interesting, but has a weird lifetime.
    // When we're transfering from one page to another (via delayed navigation)
    // we need things in memory: like the URL that we're navigating to and
    // optionally the body to POST. That cannot exist in the page.arena, because
    // the page that we have is going to be destroyed and a new page is going
    // to be created. If we used the page.arena, we'd wouldn't be able to reset
    // it between navigations.
    // So the transfer arena is meant to exist between a navigation event. It's
    // freed when the main html navigation is complete, either in pageDoneCallback
    // or pageErrorCallback. It needs to exist for this long because, if we set
    // a body, CURLOPT_POSTFIELDS does not copy the body (it optionally can, but
    // why would we want to) and requires the body to live until the transfer
    // is complete.
    fn clearTransferArena(self: *Page) void {
        _ = self.session.browser.transfer_arena.reset(.{ .retain_with_limit = 4 * 1024 });
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
        try self.window.replaceLocation(.{ .url = try self.url.toWebApi(self.arena) });
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
        const session = self.session;
        if (session.queued_navigation != null) {
            // It might seem like this should never happen. And it might not,
            // BUT..consider the case where we have script like:
            //   top.location = X;
            //   top.location = Y;
            // Will the 2nd top.location execute? You'd think not, since,
            // when we're in this function for the 1st, we'll call:
            //    session.executor.terminateExecution();
            // But, this doesn't seem guaranteed to stop on the current line.
            // My best guess is that v8 groups executes in chunks (how they are
            // chunked, I can't guess) and always executes them together.
            return;
        }

        log.debug(.browser, "delayed navigation", .{
            .url = url,
            .reason = opts.reason,
        });
        self.delayed_navigation = true;

        session.queued_navigation = .{
            .opts = opts,
            .url = try URL.stitch(session.transfer_arena, url, self.url.raw, .{ .alloc = .always }),
        };

        self.http_client.abort();

        // In v8, this throws an exception which JS code cannot catch.
        session.executor.terminateExecution();
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
            // form_data.write currently only supports this encoding, so we know this has to be the content type
            opts.header = "Content-Type: application/x-www-form-urlencoded";
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

pub const NavigateReason = enum {
    anchor,
    address_bar,
    form,
    script,
};

pub const NavigateOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: Http.Method = .GET,
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
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

    self.script_manager.addFromElement(element.?) catch |err| {
        log.warn(.browser, "dynamic script", .{ .err = err });
    };
}

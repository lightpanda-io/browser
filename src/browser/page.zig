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

    notified_network_idle: IdleNotification = .init,
    notified_network_almost_idle: IdleNotification = .init,
    auto_enable_dom_monitoring: bool = false,

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
        const self: *Page = @ptrCast(@alignCast(ctx));
        self.session.browser.runMicrotasks();
        return 5;
    }

    fn runMessageLoop(ctx: *anyopaque) ?u32 {
        const self: *Page = @ptrCast(@alignCast(ctx));
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
    pub fn dump(self: *const Page, opts: DumpOpts, out: *std.Io.Writer) !void {
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

    pub fn wait(self: *Page, wait_ms: i32) Session.WaitResult {
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

    fn _wait(self: *Page, wait_ms: i32) !Session.WaitResult {
        var timer = try std.time.Timer.start();
        var ms_remaining = wait_ms;

        var try_catch: Env.TryCatch = undefined;
        try_catch.init(self.main_context);
        defer try_catch.deinit();

        var scheduler = &self.scheduler;
        var http_client = self.http_client;

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
            switch (self.mode) {
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
                    if (try http_client.tick(ms_remaining) == .extra_socket) {
                        // data on a socket we aren't handling, return to caller
                        return .extra_socket;
                    }
                },
                .html, .parsed => {
                    // The HTML page was parsed. We now either have JS scripts to
                    // download, or scheduled tasks to execute, or both.

                    // scheduler.run could trigger new http transfers, so do not
                    // store http_client.active BEFORE this call and then use
                    // it AFTER.
                    const ms_to_next_task = try scheduler.run();

                    if (try_catch.hasCaught()) {
                        const msg = (try try_catch.err(self.arena)) orelse "unknown";
                        log.warn(.user_script, "page wait", .{ .err = msg, .src = "scheduler" });
                        return error.JsError;
                    }

                    const http_active = http_client.active;
                    const total_network_activity = http_active + http_client.intercepted;
                    if (self.notified_network_almost_idle.check(total_network_activity <= 2)) {
                        self.notifyNetworkAlmostIdle();
                    }
                    if (self.notified_network_idle.check(total_network_activity == 0)) {
                        self.notifyNetworkIdle();
                    }

                    if (http_active == 0 and exit_when_done) {
                        // we don't need to consider http_client.intercepted here
                        // because exit_when_done is true, and that can only be
                        // the case when interception isn't possible.
                        std.debug.assert(http_client.intercepted == 0);

                        const ms = ms_to_next_task orelse blk: {
                            // TODO: when jsRunner is fully replaced with the
                            // htmlRunner, we can remove the first part of this
                            // condition. jsRunner calls `page.wait` far too
                            // often to enforce this.
                            if (wait_ms > 100 and wait_ms - ms_remaining < 100) {
                                // Look, we want to exit ASAP, but we don't want
                                // to exit so fast that we've run none of the
                                // background jobs.
                                break :blk if (comptime builtin.is_test) 5 else 50;
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
                    self.mode = .{ .raw_done = @errorName(err) };
                    return err;
                },
                .raw_done => {
                    // Run scheduler to clean up any pending tasks
                    _ = try scheduler.run();

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
        std.debug.print("mode: {s}\n", .{@tagName(std.meta.activeTag(self.mode))});
        std.debug.print("load: {s}\n", .{@tagName(self.load_state)});
        {
            std.debug.print("\nactive requests: {d}\n", .{self.http_client.active});
            var n_ = self.http_client.handles.in_use.first;
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
            std.debug.print("\nqueued requests: {d}\n", .{self.http_client.queue.len()});
            var n_ = self.http_client.queue.first;
            while (n_) |n| {
                const transfer: *Http.Transfer = @fieldParentPtr("_node", n);
                std.debug.print(" - {f}\n", .{transfer.uri});
                n_ = n.next;
            }
        }

        {
            std.debug.print("\nscripts: {d}\n", .{self.script_manager.scripts.len()});
            var n_ = self.script_manager.scripts.first;
            while (n_) |n| {
                const ps: *ScriptManager.PendingScript = @fieldParentPtr("node", n);
                std.debug.print(" - {s} complete: {any}\n", .{ ps.script.url, ps.complete });
                n_ = n.next;
            }
        }

        {
            std.debug.print("\ndeferreds: {d}\n", .{self.script_manager.deferreds.len()});
            var n_ = self.script_manager.deferreds.first;
            while (n_) |n| {
                const ps: *ScriptManager.PendingScript = @fieldParentPtr("node", n);
                std.debug.print(" - {s} complete: {any}\n", .{ ps.script.url, ps.complete });
                n_ = n.next;
            }
        }

        const now = std.time.milliTimestamp();
        {
            std.debug.print("\nasyncs: {d}\n", .{self.script_manager.asyncs.len()});
            var n_ = self.script_manager.asyncs.first;
            while (n_) |n| {
                const ps: *ScriptManager.PendingScript = @fieldParentPtr("node", n);
                std.debug.print(" - {s} complete: {any}\n", .{ ps.script.url, ps.complete });
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

    fn notifyNetworkIdle(self: *Page) void {
        std.debug.assert(self.notified_network_idle == .done);
        self.session.browser.notification.dispatch(.page_network_idle, &.{
            .timestamp = timestamp(),
        });
    }

    fn notifyNetworkAlmostIdle(self: *Page) void {
        std.debug.assert(self.notified_network_almost_idle == .done);
        self.session.browser.notification.dispatch(.page_network_almost_idle, &.{
            .timestamp = timestamp(),
        });
    }

    pub fn origin(self: *const Page, arena: Allocator) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(arena);
        try self.url.origin(&aw.writer);
        return aw.written();
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

        // We dispatch page_navigate event before sending the request.
        // It ensures the event page_navigated is not dispatched before this one.
        self.session.browser.notification.dispatch(.page_navigate, &.{
            .opts = opts,
            .url = owned_url,
            .timestamp = timestamp(),
        });

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
        var self: *Page = @ptrCast(@alignCast(transfer.ctx));

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
        var self: *Page = @ptrCast(@alignCast(transfer.ctx));

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
                .text_html => .{ .html = try parser.Parser.init(mime.charsetString()) },

                .application_json,
                .text_javascript,
                .text_css,
                .text_plain,
                => blk: {
                    var p = try parser.Parser.init(mime.charsetString());
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

        var self: *Page = @ptrCast(@alignCast(ctx));
        self.clearTransferArena();

        switch (self.mode) {
            .pre => {
                // Received a response without a body like: https://httpbin.io/status/200
                // We assume we have received an OK status (checked in Client.headerCallback)
                // so we load a blank document to navigate away from any prior page.
                self.mode = .{ .parsed = {} };

                const html_doc = try parser.documentHTMLParseFromStr("");
                try self.setDocument(html_doc);

                self.documentIsComplete();
            },
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
            else => {
                log.err(.app, "unreachable mode", .{ .mode = self.mode });
                unreachable;
            },
        }
    }

    fn pageErrorCallback(ctx: *anyopaque, err: anyerror) void {
        log.err(.http, "navigate failed", .{ .err = err });

        var self: *Page = @ptrCast(@alignCast(ctx));
        self.clearTransferArena();

        switch (self.mode) {
            .html, .text => |*p| p.deinit(), // don't need the parser anymore
            else => {},
        }
        self.mode = .{ .err = err };
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
        const target = parser.eventTarget(event) orelse return;
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
            .alt_key = kbe.alt,
            .ctrl_key = kbe.ctrl,
            .meta_key = kbe.meta,
            .shift_key = kbe.shift,
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
        const target = parser.eventTarget(event) orelse return;
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
            return @ptrCast(@alignCast(state));
        }
        return null;
    }

    pub fn submitForm(self: *Page, form: *parser.Form, submitter: ?*parser.ElementHTML) !void {
        const FormData = @import("xhr/form_data.zig").FormData;

        const transfer_arena = self.session.transfer_arena;
        var form_data = try FormData.fromForm(form, submitter, self);

        const encoding = try parser.elementGetAttribute(@ptrCast(@alignCast(form)), "enctype");

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try form_data.write(encoding, buf.writer(transfer_arena));

        const method = try parser.elementGetAttribute(@ptrCast(@alignCast(form)), "method") orelse "";
        var action = try parser.elementGetAttribute(@ptrCast(@alignCast(form)), "action") orelse self.url.raw;

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
                    self.* = .{ .triggered = milliTimestamp() };
                },
                .triggered => |ms| {
                    // The condition was already triggered and was triggered
                    // again. When this condition holds for 500+ms, we'll send
                    // a notification.
                    if (milliTimestamp() - ms >= 500) {
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

fn timestamp() u32 {
    return @import("../datetime.zig").timestamp();
}
fn milliTimestamp() u64 {
    return @import("../datetime.zig").milliTimestamp();
}

// A callback from libdom whenever a script tag is added to the DOM.
// element is guaranteed to be a script element.
// The script tag might not have a src. It might be any attribute, like
// `nomodule`, `defer` and `async`. `Script.init` will return null on `nomodule`
// so that's handled. And because we're only executing the inline <script> tags
// after the document is loaded, it's ok to execute any async and defer scripts
// immediately.
pub export fn scriptAddedCallback(ctx: ?*anyopaque, element: ?*parser.Element) callconv(.c) void {
    const self: *Page = @ptrCast(@alignCast(ctx.?));

    if (self.delayed_navigation) {
        // if we're planning on navigating to another page, don't run this script
        return;
    }

    // It's possible for a script to be dynamically added without a src.
    //   const s = document.createElement('script');
    //   document.getElementsByTagName('body')[0].appendChild(s);
    // The src can be set after. We handle that in HTMLScriptElement.set_src,
    // but it's important we don't pass such elements to the script_manager
    // here, else the script_manager will flag it as already-processed.
    _ = parser.elementGetAttribute(element.?, "src") catch return orelse return;

    self.script_manager.addFromElement(element.?) catch |err| {
        log.warn(.browser, "dynamic script", .{ .err = err });
    };
}

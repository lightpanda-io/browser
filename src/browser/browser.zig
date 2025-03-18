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

const Types = @import("root").Types;

const parser = @import("netsurf");
const Dump = @import("dump.zig");
const Mime = @import("mime.zig").Mime;

const jsruntime = @import("jsruntime");
const Loop = jsruntime.Loop;
const Env = jsruntime.Env;
const Module = jsruntime.Module;

const App = @import("../app.zig").App;
const apiweb = @import("../apiweb.zig");

const Window = @import("../html/window.zig").Window;
const Walker = @import("../dom/walker.zig").WalkerDepthFirst;

const URL = @import("../url/url.zig").URL;
const Location = @import("../html/location.zig").Location;

const storage = @import("../storage/storage.zig");

const http = @import("../http/client.zig");
const UserContext = @import("../user_context.zig").UserContext;

const polyfill = @import("../polyfill/polyfill.zig");

const log = std.log.scoped(.browser);

pub const user_agent = "Lightpanda/1.0";

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
// TODO allow multiple sessions per browser.
pub const Browser = struct {
    app: *App,
    session: ?*Session,
    allocator: Allocator,
    http_client: http.Client,
    session_pool: SessionPool,
    page_arena: std.heap.ArenaAllocator,

    const SessionPool = std.heap.MemoryPool(Session);

    pub fn init(app: *App) !Browser {
        const allocator = app.allocator;
        return .{
            .app = app,
            .session = null,
            .allocator = allocator,
            .session_pool = SessionPool.init(allocator),
            .http_client = try http.Client.init(allocator, 5),
            .page_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Browser) void {
        self.closeSession();
        self.http_client.deinit();
        self.session_pool.deinit();
        self.page_arena.deinit();
    }

    pub fn newSession(self: *Browser, ctx: anytype) !*Session {
        self.closeSession();

        const session = try self.session_pool.create();
        try Session.init(session, self, ctx);
        self.session = session;
        return session;
    }

    fn closeSession(self: *Browser) void {
        if (self.session) |session| {
            session.deinit();
            self.session_pool.destroy(session);
            self.session = null;
        }
    }
};

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
pub const Session = struct {
    app: *App,

    browser: *Browser,

    // The arena is used only to bound the js env init b/c it leaks memory.
    // see https://github.com/lightpanda-io/jsruntime-lib/issues/181
    //
    // The arena is initialised with self.alloc allocator.
    // all others Session deps use directly self.alloc and not the arena.
    arena: std.heap.ArenaAllocator,

    env: Env,
    inspector: jsruntime.Inspector,

    window: Window,

    // TODO move the shed to the browser?
    storage_shed: storage.Shed,
    page: ?Page = null,
    http_client: *http.Client,

    jstypes: [Types.len]usize = undefined,

    fn init(self: *Session, browser: *Browser, ctx: anytype) !void {
        const app = browser.app;
        const allocator = app.allocator;
        self.* = .{
            .app = app,
            .env = undefined,
            .browser = browser,
            .inspector = undefined,
            .http_client = &browser.http_client,
            .storage_shed = storage.Shed.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .window = Window.create(null, .{ .agent = user_agent }),
        };

        const arena = self.arena.allocator();
        Env.init(&self.env, arena, app.loop, null);
        errdefer self.env.deinit();
        try self.env.load(&self.jstypes);

        const ContextT = @TypeOf(ctx);
        const InspectorContainer = switch (@typeInfo(ContextT)) {
            .@"struct" => ContextT,
            .pointer => |ptr| ptr.child,
            .void => NoopInspector,
            else => @compileError("invalid context type"),
        };

        // const ctx_opaque = @as(*anyopaque, @ptrCast(ctx));
        self.inspector = try jsruntime.Inspector.init(
            arena,
            &self.env,
            if (@TypeOf(ctx) == void) @constCast(@ptrCast(&{})) else ctx,
            InspectorContainer.onInspectorResponse,
            InspectorContainer.onInspectorEvent,
        );
        self.env.setInspector(self.inspector);

        try self.env.setModuleLoadFn(self, Session.fetchModule);
    }

    fn deinit(self: *Session) void {
        if (self.page != null) {
            self.removePage();
        }
        self.env.deinit();
        self.arena.deinit();
        self.storage_shed.deinit();
    }

    fn fetchModule(ctx: *anyopaque, referrer: ?jsruntime.Module, specifier: []const u8) !jsruntime.Module {
        _ = referrer;

        const self: *Session = @ptrCast(@alignCast(ctx));
        const page = &(self.page orelse return error.NoPage);

        log.debug("fetch module: specifier: {s}", .{specifier});
        // fetchModule is called within the context of processing a page.
        // Use the page_arena for this, which has a more appropriate lifetime
        // and which has more retained memory between sessions and pages.
        const arena = self.browser.page_arena.allocator();
        const body = try page.fetchData(
            arena,
            specifier,
            if (page.current_script) |s| s.src else null,
        );
        return self.env.compileModule(body, specifier);
    }

    pub fn callInspector(self: *Session, msg: []const u8) void {
        self.inspector.send(self.env, msg);
    }

    // NOTE: the caller is not the owner of the returned value,
    // the pointer on Page is just returned as a convenience
    pub fn createPage(self: *Session, aux_data: ?[]const u8) !*Page {
        std.debug.assert(self.page == null);

        _ = self.browser.page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });

        self.page = Page.init(self);
        const page = &self.page.?;

        // start JS env
        log.debug("start js env", .{});
        try self.env.start();

        if (comptime builtin.is_test == false) {
            // By not loading this during tests, we aren't required to load
            // all of the interfaces into zig-js-runtime.
            log.debug("setup global env", .{});
            try self.env.bindGlobal(&self.window);
        }

        // load polyfills
        // TODO: change to 'env' when https://github.com/lightpanda-io/zig-js-runtime/pull/285 lands
        try polyfill.load(self.arena.allocator(), &self.env);

        // inspector
        self.contextCreated(page, aux_data);

        return page;
    }

    pub fn removePage(self: *Session) void {
        std.debug.assert(self.page != null);

        // Reset all existing callbacks.
        self.app.loop.reset();

        self.env.stop();
        // TODO unload document: https://html.spec.whatwg.org/#unloading-documents

        self.window.replaceLocation(null) catch |e| {
            log.err("reset window location: {any}", .{e});
        };

        // clear netsurf memory arena.
        parser.deinit();

        self.page = null;
    }

    pub fn currentPage(self: *Session) ?*Page {
        return &(self.page orelse return null);
    }

    fn contextCreated(self: *Session, page: *Page, aux_data: ?[]const u8) void {
        log.debug("inspector context created", .{});
        self.inspector.contextCreated(&self.env, "", page.origin orelse "://", aux_data);
    }
};

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
// The page handle all its memory in an arena allocator. The arena is reseted
// when end() is called.
pub const Page = struct {
    arena: Allocator,
    session: *Session,
    doc: ?*parser.Document = null,

    // handle url
    rawuri: ?[]const u8 = null,
    uri: std.Uri = undefined,
    origin: ?[]const u8 = null,

    // html url and location
    url: ?URL = null,
    location: Location = .{},

    raw_data: ?[]const u8 = null,

    // current_script is the script currently evaluated by the page.
    // current_script could by fetch module to resolve module's url to fetch.
    current_script: ?*const Script = null,

    fn init(session: *Session) Page {
        return .{
            .session = session,
            .arena = session.browser.page_arena.allocator(),
        };
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

    pub fn wait(self: *Page) !void {
        // try catch
        var try_catch: jsruntime.TryCatch = undefined;
        try_catch.init(&self.session.env);
        defer try_catch.deinit();

        self.session.env.wait() catch |err| {
            // the js env could not be started if the document wasn't an HTML.
            if (err == error.EnvNotStarted) return;

            const arena = self.arena;
            if (try try_catch.err(arena, &self.session.env)) |msg| {
                defer arena.free(msg);
                log.info("wait error: {s}", .{msg});
                return;
            }
        };
        log.debug("wait: OK", .{});
    }

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    // - aux_data: extra data forwarded to the Inspector
    // see Inspector.contextCreated
    pub fn navigate(self: *Page, uri: []const u8, aux_data: ?[]const u8) !void {
        const arena = self.arena;

        log.debug("starting GET {s}", .{uri});

        // if the uri is about:blank, nothing to do.
        if (std.mem.eql(u8, "about:blank", uri)) {
            return;
        }

        // own the url
        self.rawuri = try arena.dupe(u8, uri);
        self.uri = std.Uri.parse(self.rawuri.?) catch try std.Uri.parseAfterScheme("", self.rawuri.?);

        self.url = try URL.constructor(arena, self.rawuri.?, null);
        self.location.url = &self.url.?;
        try self.session.window.replaceLocation(&self.location);

        // prepare origin value.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        try self.uri.writeToStream(.{
            .scheme = true,
            .authority = true,
        }, buf.writer(arena));
        self.origin = buf.items;

        // TODO handle fragment in url.

        self.session.app.telemetry.record(.{ .navigate = .{
            .proxy = false,
            .tls = std.ascii.eqlIgnoreCase(self.uri.scheme, "https"),
        } });

        // load the data
        var request = try self.session.http_client.request(.GET, self.uri);
        defer request.deinit();
        var response = try request.sendSync(.{});

        const header = response.header;
        log.info("GET {any} {d}", .{ self.uri, header.status });

        const ct = response.header.get("content-type") orelse {
            // no content type in HTTP headers.
            // TODO try to sniff mime type from the body.
            log.info("no content-type HTTP header", .{});
            return;
        };

        log.debug("header content-type: {s}", .{ct});
        var mime = try Mime.parse(arena, ct);
        defer mime.deinit();

        if (mime.isHTML()) {
            try self.loadHTMLDoc(&response, mime.charset orelse "utf-8", aux_data);
        } else {
            log.info("non-HTML document: {s}", .{ct});
            var arr: std.ArrayListUnmanaged(u8) = .{};
            while (try response.next()) |data| {
                try arr.appendSlice(arena, try arena.dupe(u8, data));
            }
            // save the body into the page.
            self.raw_data = arr.items;
        }
    }

    // https://html.spec.whatwg.org/#read-html
    fn loadHTMLDoc(self: *Page, reader: anytype, charset: []const u8, aux_data: ?[]const u8) !void {
        const arena = self.arena;

        // start netsurf memory arena.
        try parser.init();

        log.debug("parse html with charset {s}", .{charset});

        const ccharset = try arena.dupeZ(u8, charset);

        const html_doc = try parser.documentHTMLParse(reader, ccharset);
        const doc = parser.documentHTMLToDocument(html_doc);

        // save a document's pointer in the page.
        self.doc = doc;

        // TODO set document.readyState to interactive
        // https://html.spec.whatwg.org/#reporting-document-loading-status

        // inject the URL to the document including the fragment.
        try parser.documentSetDocumentURI(doc, self.rawuri orelse "about:blank");

        const session = self.session;
        // TODO set the referrer to the document.
        try session.window.replaceDocument(html_doc);
        session.window.setStorageShelf(
            try session.storage_shed.getOrPut(self.origin orelse "null"),
        );

        // https://html.spec.whatwg.org/#read-html

        // inspector
        session.contextCreated(self, aux_data);

        // replace the user context document with the new one.
        try session.env.setUserContext(.{
            .document = html_doc,
            .http_client = @ptrCast(self.session.http_client),
        });

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
            parser.toEventTarget(Window, &self.session.window),
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
            try s.eval(self.arena, &self.session.env, text);
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
    fn fetchData(self: *const Page, arena: Allocator, src: []const u8, base: ?[]const u8) ![]const u8 {
        log.debug("starting fetch {s}", .{src});

        var buffer: [1024]u8 = undefined;
        var b: []u8 = buffer[0..];

        var res_src = src;

        // if a base path is given, we resolve src using base.
        if (base) |_base| {
            const dir = std.fs.path.dirname(_base);
            if (dir) |_dir| {
                res_src = try std.fs.path.resolve(arena, &.{ _dir, src });
            }
        }
        const u = try std.Uri.resolve_inplace(self.uri, res_src, &b);

        var request = try self.session.http_client.request(.GET, u);
        defer request.deinit();
        var response = try request.sendSync(.{});

        log.info("fetch {any}: {d}", .{ u, response.header.status });

        if (response.header.status != 200) {
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

    fn fetchScript(self: *const Page, s: *const Script) !void {
        const arena = self.arena;
        const body = try self.fetchData(arena, s.src, null);
        try s.eval(arena, &self.session.env, body);
    }

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
            if (std.mem.eql(u8, stype.?, "module")) return .module;

            return .unknown;
        }

        fn eval(self: Script, arena: Allocator, env: *const Env, body: []const u8) !void {
            var try_catch: jsruntime.TryCatch = undefined;
            try_catch.init(env);
            defer try_catch.deinit();

            const res = switch (self.kind) {
                .unknown => return error.UnknownScript,
                .javascript => env.exec(body, self.src),
                .module => env.module(body, self.src),
            } catch {
                if (try try_catch.err(arena, env)) |msg| {
                    log.info("eval script {s}: {s}", .{ self.src, msg });
                }
                return FetchError.JsErr;
            };

            if (builtin.mode == .Debug) {
                const msg = try res.toString(arena, env);
                log.debug("eval script {s}: {s}", .{ self.src, msg });
            }
        }
    };
};

const NoopInspector = struct {
    pub fn onInspectorResponse(_: *anyopaque, _: u32, _: []const u8) void {}
    pub fn onInspectorEvent(_: *anyopaque, _: []const u8) void {}
};

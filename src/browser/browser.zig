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

const Types = @import("root").Types;

const parser = @import("netsurf");
const Loader = @import("loader.zig").Loader;
const Dump = @import("dump.zig");
const Mime = @import("mime.zig");

const jsruntime = @import("jsruntime");
const Loop = jsruntime.Loop;
const Env = jsruntime.Env;
const Module = jsruntime.Module;

const apiweb = @import("../apiweb.zig");

const Window = @import("../html/window.zig").Window;
const Walker = @import("../dom/walker.zig").WalkerDepthFirst;

const URL = @import("../url/url.zig").URL;
const Location = @import("../html/location.zig").Location;

const storage = @import("../storage/storage.zig");

const FetchResult = @import("../http/Client.zig").Client.FetchResult;

const UserContext = @import("../user_context.zig").UserContext;
const HttpClient = @import("asyncio").Client;

const polyfill = @import("../polyfill/polyfill.zig");

const log = std.log.scoped(.browser);

pub const user_agent = "Lightpanda/1.0";

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
// TODO allow multiple sessions per browser.
pub const Browser = struct {
    session: Session = undefined,
    agent: []const u8 = user_agent,

    const uri = "about:blank";

    pub fn init(self: *Browser, alloc: std.mem.Allocator, loop: *Loop, vm: jsruntime.VM) !void {
        // We want to ensure the caller initialised a VM, but the browser
        // doesn't use it directly...
        _ = vm;

        try Session.init(&self.session, alloc, loop, uri);
    }

    pub fn deinit(self: *Browser) void {
        self.session.deinit();
    }

    pub fn newSession(
        self: *Browser,
        alloc: std.mem.Allocator,
        loop: *jsruntime.Loop,
    ) !void {
        self.session.deinit();
        try Session.init(&self.session, alloc, loop, uri);
    }
};

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
pub const Session = struct {
    // allocator used to init the arena.
    alloc: std.mem.Allocator,

    // The arena is used only to bound the js env init b/c it leaks memory.
    // see https://github.com/lightpanda-io/jsruntime-lib/issues/181
    //
    // The arena is initialised with self.alloc allocator.
    // all others Session deps use directly self.alloc and not the arena.
    arena: std.heap.ArenaAllocator,

    uri: []const u8,

    // TODO handle proxy
    loader: Loader,
    env: Env = undefined,
    inspector: ?jsruntime.Inspector = null,

    window: Window,

    // TODO move the shed to the browser?
    storageShed: storage.Shed,
    page: ?Page = null,
    httpClient: HttpClient,

    jstypes: [Types.len]usize = undefined,

    fn init(self: *Session, alloc: std.mem.Allocator, loop: *Loop, uri: []const u8) !void {
        self.* = Session{
            .uri = uri,
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .window = Window.create(null, .{ .agent = user_agent }),
            .loader = Loader.init(alloc),
            .storageShed = storage.Shed.init(alloc),
            .httpClient = undefined,
        };

        Env.init(&self.env, self.arena.allocator(), loop, null);
        self.httpClient = .{ .allocator = alloc };
        try self.env.load(&self.jstypes);
    }

    fn fetchModule(ctx: *anyopaque, referrer: ?jsruntime.Module, specifier: []const u8) !jsruntime.Module {
        _ = referrer;

        const self: *Session = @ptrCast(@alignCast(ctx));

        if (self.page == null) return error.NoPage;

        log.debug("fetch module: specifier: {s}", .{specifier});
        const alloc = self.arena.allocator();
        const body = try self.page.?.fetchData(alloc, specifier);
        defer alloc.free(body);

        return self.env.compileModule(body, specifier);
    }

    fn deinit(self: *Session) void {
        if (self.page) |*p| p.end();

        if (self.inspector) |inspector| {
            inspector.deinit(self.alloc);
        }

        self.env.deinit();
        self.arena.deinit();

        self.httpClient.deinit();
        self.loader.deinit();
        self.storageShed.deinit();
    }

    pub fn initInspector(
        self: *Session,
        ctx: anytype,
        onResp: jsruntime.InspectorOnResponseFn,
        onEvent: jsruntime.InspectorOnEventFn,
    ) !void {
        const ctx_opaque = @as(*anyopaque, @ptrCast(ctx));
        self.inspector = try jsruntime.Inspector.init(self.alloc, self.env, ctx_opaque, onResp, onEvent);
        self.env.setInspector(self.inspector.?);
    }

    pub fn callInspector(self: *Session, msg: []const u8) void {
        if (self.inspector) |inspector| {
            inspector.send(msg, self.env);
        } else {
            @panic("No Inspector");
        }
    }

    // NOTE: the caller is not the owner of the returned value,
    // the pointer on Page is just returned as a convenience
    pub fn createPage(self: *Session) !*Page {
        if (self.page != null) return error.SessionPageExists;
        const p: Page = undefined;
        self.page = p;
        Page.init(&self.page.?, self.alloc, self);
        return &self.page.?;
    }
};

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
// The page handle all its memory in an arena allocator. The arena is reseted
// when end() is called.
pub const Page = struct {
    arena: std.heap.ArenaAllocator,
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

    fn init(
        self: *Page,
        alloc: std.mem.Allocator,
        session: *Session,
    ) void {
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .session = session,
        };
    }

    // start js env.
    // - auxData: extra data forwarded to the Inspector
    // see Inspector.contextCreated
    pub fn start(self: *Page, auxData: ?[]const u8) !void {
        // start JS env
        log.debug("start js env", .{});
        try self.session.env.start();

        // register the module loader
        try self.session.env.setModuleLoadFn(self.session, Session.fetchModule);

        // add global objects
        log.debug("setup global env", .{});
        try self.session.env.bindGlobal(&self.session.window);

        // load polyfills
        try polyfill.load(self.arena.allocator(), self.session.env);

        // inspector
        if (self.session.inspector) |inspector| {
            log.debug("inspector context created", .{});
            inspector.contextCreated(self.session.env, "", self.origin orelse "://", auxData);
        }
    }

    // reset js env and mem arena.
    pub fn end(self: *Page) void {
        self.session.env.stop();
        // TODO unload document: https://html.spec.whatwg.org/#unloading-documents

        if (self.url) |*u| u.deinit(self.arena.allocator());
        self.url = null;
        self.location.url = null;
        self.session.window.replaceLocation(&self.location) catch |e| {
            log.err("reset window location: {any}", .{e});
        };

        // clear netsurf memory arena.
        parser.deinit();

        _ = self.arena.reset(.free_all);
    }

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
        self.session.page = null;
    }

    // dump writes the page content into the given file.
    pub fn dump(self: *Page, out: std.fs.File) !void {

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
        try_catch.init(self.session.env);
        defer try_catch.deinit();

        self.session.env.wait() catch |err| {
            // the js env could not be started if the document wasn't an HTML.
            if (err == error.EnvNotStarted) return;

            const alloc = self.arena.allocator();
            if (try try_catch.err(alloc, self.session.env)) |msg| {
                defer alloc.free(msg);
                log.info("wait error: {s}", .{msg});
                return;
            }
        };
        log.debug("wait: OK", .{});
    }

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    // - auxData: extra data forwarded to the Inspector
    // see Inspector.contextCreated
    pub fn navigate(self: *Page, uri: []const u8, auxData: ?[]const u8) !void {
        const alloc = self.arena.allocator();

        log.debug("starting GET {s}", .{uri});

        // if the uri is about:blank, nothing to do.
        if (std.mem.eql(u8, "about:blank", uri)) {
            return;
        }

        // own the url
        if (self.rawuri) |prev| alloc.free(prev);
        self.rawuri = try alloc.dupe(u8, uri);
        self.uri = std.Uri.parse(self.rawuri.?) catch try std.Uri.parseAfterScheme("", self.rawuri.?);

        if (self.url) |*prev| prev.deinit(alloc);
        self.url = try URL.constructor(alloc, self.rawuri.?, null);
        self.location.url = &self.url.?;
        try self.session.window.replaceLocation(&self.location);

        // prepare origin value.
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try self.uri.writeToStream(.{
            .scheme = true,
            .authority = true,
        }, buf.writer());
        self.origin = try buf.toOwnedSlice();

        // TODO handle fragment in url.

        // load the data
        var resp = try self.session.loader.get(alloc, self.uri);
        defer resp.deinit();

        const req = resp.req;

        log.info("GET {any} {d}", .{ self.uri, @intFromEnum(req.response.status) });

        // TODO handle redirection
        log.debug("{?} {d} {s}", .{
            req.response.version,
            @intFromEnum(req.response.status),
            req.response.reason,
            // TODO log headers
        });

        // TODO handle charset
        // https://html.spec.whatwg.org/#content-type
        var it = req.response.iterateHeaders();
        var ct: ?[]const u8 = null;
        while (true) {
            const h = it.next() orelse break;
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                ct = try alloc.dupe(u8, h.value);
            }
        }
        if (ct == null) {
            // no content type in HTTP headers.
            // TODO try to sniff mime type from the body.
            log.info("no content-type HTTP header", .{});
            return;
        }
        defer alloc.free(ct.?);

        log.debug("header content-type: {s}", .{ct.?});
        const mime = try Mime.parse(ct.?);
        if (mime.eql(Mime.HTML)) {
            try self.loadHTMLDoc(req.reader(), mime.charset orelse "utf-8", auxData);
        } else {
            log.info("non-HTML document: {s}", .{ct.?});

            // save the body into the page.
            self.raw_data = try req.reader().readAllAlloc(alloc, 16 * 1024 * 1024);
        }
    }

    // https://html.spec.whatwg.org/#read-html
    fn loadHTMLDoc(self: *Page, reader: anytype, charset: []const u8, auxData: ?[]const u8) !void {
        const alloc = self.arena.allocator();

        // start netsurf memory arena.
        try parser.init();

        log.debug("parse html with charset {s}", .{charset});

        const ccharset = try alloc.dupeZ(u8, charset);
        defer alloc.free(ccharset);

        const html_doc = try parser.documentHTMLParse(reader, ccharset);
        const doc = parser.documentHTMLToDocument(html_doc);

        // save a document's pointer in the page.
        self.doc = doc;

        // TODO set document.readyState to interactive
        // https://html.spec.whatwg.org/#reporting-document-loading-status

        // inject the URL to the document including the fragment.
        try parser.documentSetDocumentURI(doc, self.rawuri orelse "about:blank");

        // TODO set the referrer to the document.

        try self.session.window.replaceDocument(html_doc);
        self.session.window.setStorageShelf(
            try self.session.storageShed.getOrPut(self.origin orelse "null"),
        );

        // https://html.spec.whatwg.org/#read-html

        // inspector
        if (self.session.inspector) |inspector| {
            inspector.contextCreated(self.session.env, "", self.origin.?, auxData);
        }

        // replace the user context document with the new one.
        try self.session.env.setUserContext(.{
            .document = html_doc,
            .httpClient = &self.session.httpClient,
        });

        // browse the DOM tree to retrieve scripts
        // TODO execute the synchronous scripts during the HTL parsing.
        // TODO fetch the script resources concurrently but execute them in the
        // declaration order for synchronous ones.

        // sasync stores scripts which can be run asynchronously.
        // for now they are just run after the non-async one in order to
        // dispatch DOMContentLoaded the sooner as possible.
        var sasync = std.ArrayList(Script).init(alloc);
        defer sasync.deinit();

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
            if (script.isasync) {
                try sasync.append(script);
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
            self.evalScript(script) catch |err| log.warn("evaljs: {any}", .{err});
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
            self.evalScript(s) catch |err| log.warn("evaljs: {any}", .{err});
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
    fn evalScript(self: *Page, s: Script) !void {
        const alloc = self.arena.allocator();

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
            try s.eval(alloc, self.session.env, text);
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

    // the caller owns the returned string
    fn fetchData(self: *Page, alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
        log.debug("starting fetch {s}", .{src});

        var buffer: [1024]u8 = undefined;
        var b: []u8 = buffer[0..];
        const u = try std.Uri.resolve_inplace(self.uri, src, &b);

        var fetchres = try self.session.loader.get(alloc, u);
        defer fetchres.deinit();

        const resp = fetchres.req.response;

        log.info("fetch {any}: {d}", .{ u, resp.status });

        if (resp.status != .ok) return FetchError.BadStatusCode;

        // TODO check content-type
        const body = try fetchres.req.reader().readAllAlloc(alloc, 16 * 1024 * 1024);

        // check no body
        if (body.len == 0) return FetchError.NoBody;

        return body;
    }

    // fetchScript senf a GET request to the src and execute the script
    // received.
    fn fetchScript(self: *Page, s: Script) !void {
        const alloc = self.arena.allocator();
        const body = try self.fetchData(alloc, s.src);
        defer alloc.free(body);

        try s.eval(alloc, self.session.env, body);
    }

    const Script = struct {
        element: *parser.Element,
        kind: Kind,
        isasync: bool,

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
                .kind = kind(try parser.elementGetAttribute(e, "type")),
                .isasync = try parser.elementGetAttribute(e, "async") != null,

                .src = try parser.elementGetAttribute(e, "src") orelse "inline",
            };
        }

        // > type
        // > Attribute is not set (default), an empty string, or a JavaScript MIME
        // > type indicates that the script is a "classic script", containing
        // > JavaScript code.
        // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#attribute_is_not_set_default_an_empty_string_or_a_javascript_mime_type
        fn kind(stype: ?[]const u8) Kind {
            if (stype == null or stype.?.len == 0) return .javascript;
            if (std.mem.eql(u8, stype.?, "application/javascript")) return .javascript;
            if (std.mem.eql(u8, stype.?, "module")) return .module;

            return .unknown;
        }

        fn eval(self: Script, alloc: std.mem.Allocator, env: Env, body: []const u8) !void {
            var try_catch: jsruntime.TryCatch = undefined;
            try_catch.init(env);
            defer try_catch.deinit();

            const res = switch (self.kind) {
                .unknown => return error.UnknownScript,
                .javascript => env.exec(body, self.src),
                .module => env.module(body, self.src),
            } catch {
                if (try try_catch.err(alloc, env)) |msg| {
                    defer alloc.free(msg);
                    log.info("eval script {s}: {s}", .{ self.src, msg });
                }
                return FetchError.JsErr;
            };

            if (builtin.mode == .Debug) {
                const msg = try res.toString(alloc, env);
                defer alloc.free(msg);
                log.debug("eval script {s}: {s}", .{ self.src, msg });
            }
        }
    };
};

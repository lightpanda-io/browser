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

const apiweb = @import("../apiweb.zig");

const Window = @import("../html/window.zig").Window;
const Walker = @import("../dom/walker.zig").WalkerDepthFirst;

const storage = @import("../storage/storage.zig");

const FetchResult = @import("../http/Client.zig").Client.FetchResult;

const UserContext = @import("../user_context.zig").UserContext;
const HttpClient = @import("../async/Client.zig");

const log = std.log.scoped(.browser);

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
// TODO allow multiple sessions per browser.
pub const Browser = struct {
    session: *Session,

    pub fn init(alloc: std.mem.Allocator) !Browser {
        // We want to ensure the caller initialised a VM, but the browser
        // doesn't use it directly...

        return Browser{
            .session = try Session.init(alloc, "about:blank"),
        };
    }

    pub fn deinit(self: *Browser) void {
        self.session.deinit();
    }

    pub fn currentSession(self: *Browser) *Session {
        return self.session;
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
    loop: Loop,
    inspector: ?jsruntime.Inspector = null,
    window: Window,
    // TODO move the shed to the browser?
    storageShed: storage.Shed,
    page: ?*Page = null,
    httpClient: HttpClient,

    jstypes: [Types.len]usize = undefined,

    fn init(alloc: std.mem.Allocator, uri: []const u8) !*Session {
        var self = try alloc.create(Session);
        self.* = Session{
            .uri = uri,
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .window = Window.create(null),
            .loader = Loader.init(alloc),
            .loop = try Loop.init(alloc),
            .storageShed = storage.Shed.init(alloc),
            .httpClient = undefined,
        };

        self.env = try Env.init(self.arena.allocator(), &self.loop, null);
        self.httpClient = .{ .allocator = alloc, .loop = &self.loop };
        try self.env.load(&self.jstypes);

        return self;
    }

    fn deinit(self: *Session) void {
        if (self.page) |page| page.end();

        if (self.inspector) |inspector| {
            inspector.deinit(self.alloc);
        }

        self.env.deinit();
        self.arena.deinit();

        self.httpClient.deinit();
        self.loader.deinit();
        self.storageShed.deinit();
        self.loop.deinit();
        self.alloc.destroy(self);
    }

    pub fn setInspector(
        self: *Session,
        ctx: *anyopaque,
        onResp: jsruntime.InspectorOnResponseFn,
        onEvent: jsruntime.InspectorOnEventFn,
    ) !void {
        self.inspector = try jsruntime.Inspector.init(self.alloc, self.env, ctx, onResp, onEvent);
        self.env.setInspector(self.inspector.?);
    }

    pub fn createPage(self: *Session) !Page {
        return Page.init(self.alloc, self);
    }

    pub fn callInspector(self: *Session, msg: []const u8) void {
        if (self.inspector) |inspector| {
            inspector.send(msg, self.env);
        }
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

    raw_data: ?[]const u8 = null,

    fn init(
        alloc: std.mem.Allocator,
        session: *Session,
    ) !Page {
        if (session.page != null) return error.SessionPageExists;
        var page = Page{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .session = session,
        };
        session.page = &page;
        return page;
    }

    // reset js env and mem arena.
    pub fn end(self: *Page) void {
        self.session.env.stop();
        // TODO unload document: https://html.spec.whatwg.org/#unloading-documents

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
    pub fn navigate(self: *Page, uri: []const u8, auxData: ?[]const u8) !void {
        const alloc = self.arena.allocator();

        log.debug("starting GET {s}", .{uri});

        // own the url
        if (self.rawuri) |prev| alloc.free(prev);
        self.rawuri = try alloc.dupe(u8, uri);
        self.uri = std.Uri.parse(self.rawuri.?) catch try std.Uri.parseAfterScheme("", self.rawuri.?);

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

        log.info("GET {any} {d}", .{ self.uri, req.response.status });

        // TODO handle redirection
        if (req.response.status != .ok) {
            log.debug("{?} {d} {s}", .{
                req.response.version,
                req.response.status,
                req.response.reason,
                // TODO log headers
            });
            return error.BadStatusCode;
        }

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

        self.session.window.replaceDocument(html_doc);
        self.session.window.setStorageShelf(
            try self.session.storageShed.getOrPut(self.origin orelse "null"),
        );

        // https://html.spec.whatwg.org/#read-html

        // start JS env
        // TODO load the js env concurrently with the HTML parsing.
        log.debug("start js env", .{});
        try self.session.env.start();

        // inspector
        if (self.session.inspector) |inspector| {
            inspector.contextCreated(self.session.env, "", self.origin.?, auxData);
        }

        // replace the user context document with the new one.
        try self.session.env.setUserContext(.{
            .document = html_doc,
            .httpClient = &self.session.httpClient,
        });

        // add global objects
        log.debug("setup global env", .{});
        try self.session.env.bindGlobal(&self.session.window);

        // browse the DOM tree to retrieve scripts
        // TODO execute the synchronous scripts during the HTL parsing.
        // TODO fetch the script resources concurrently but execute them in the
        // declaration order for synchronous ones.

        // sasync stores scripts which can be run asynchronously.
        // for now they are just run after the non-async one in order to
        // dispatch DOMContentLoaded the sooner as possible.
        var sasync = std.ArrayList(*parser.Element).init(alloc);
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
            const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(e)));

            // ignore non-script tags
            if (tag != .script) continue;

            // ignore non-js script.
            // > type
            // > Attribute is not set (default), an empty string, or a JavaScript MIME
            // > type indicates that the script is a "classic script", containing
            // > JavaScript code.
            // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#attribute_is_not_set_default_an_empty_string_or_a_javascript_mime_type
            const stype = try parser.elementGetAttribute(e, "type");
            if (!isJS(stype)) {
                continue;
            }

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
            if (try parser.elementGetAttribute(e, "async") != null) {
                try sasync.append(e);
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
            self.evalScript(e) catch |err| log.warn("evaljs: {any}", .{err});
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
        for (sasync.items) |e| {
            try parser.documentHTMLSetCurrentScript(html_doc, @ptrCast(e));
            self.evalScript(e) catch |err| log.warn("evaljs: {any}", .{err});
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
    fn evalScript(self: *Page, e: *parser.Element) !void {
        const alloc = self.arena.allocator();

        // https://html.spec.whatwg.org/multipage/webappapis.html#fetch-a-classic-script
        const opt_src = try parser.elementGetAttribute(e, "src");
        if (opt_src) |src| {
            log.debug("starting GET {s}", .{src});

            self.fetchScript(src) catch |err| {
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

        var try_catch: jsruntime.TryCatch = undefined;
        try_catch.init(self.session.env);
        defer try_catch.deinit();

        const opt_text = try parser.nodeTextContent(parser.elementToNode(e));
        if (opt_text) |text| {
            // TODO handle charset attribute
            const res = self.session.env.exec(text, "") catch {
                if (try try_catch.err(alloc, self.session.env)) |msg| {
                    defer alloc.free(msg);
                    log.info("eval inline {s}: {s}", .{ text, msg });
                }
                return;
            };

            if (builtin.mode == .Debug) {
                const msg = try res.toString(alloc, self.session.env);
                defer alloc.free(msg);
                log.debug("eval inline {s}", .{msg});
            }
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

    // fetchScript senf a GET request to the src and execute the script
    // received.
    fn fetchScript(self: *Page, src: []const u8) !void {
        const alloc = self.arena.allocator();

        log.debug("starting fetch script {s}", .{src});

        var buffer: [1024]u8 = undefined;
        var b: []u8 = buffer[0..];
        const u = try std.Uri.resolve_inplace(self.uri, src, &b);

        var fetchres = try self.session.loader.get(alloc, u);
        defer fetchres.deinit();

        const resp = fetchres.req.response;

        log.info("fech script {any}: {d}", .{ u, resp.status });

        if (resp.status != .ok) return FetchError.BadStatusCode;

        // TODO check content-type
        const body = try fetchres.req.reader().readAllAlloc(alloc, 16 * 1024 * 1024);
        defer alloc.free(body);

        // check no body
        if (body.len == 0) return FetchError.NoBody;

        var try_catch: jsruntime.TryCatch = undefined;
        try_catch.init(self.session.env);
        defer try_catch.deinit();

        const res = self.session.env.exec(body, src) catch {
            if (try try_catch.err(alloc, self.session.env)) |msg| {
                defer alloc.free(msg);
                log.info("eval remote {s}: {s}", .{ src, msg });
            }
            return FetchError.JsErr;
        };

        if (builtin.mode == .Debug) {
            const msg = try res.toString(alloc, self.session.env);
            defer alloc.free(msg);
            log.debug("eval remote {s}: {s}", .{ src, msg });
        }
    }

    // > type
    // > Attribute is not set (default), an empty string, or a JavaScript MIME
    // > type indicates that the script is a "classic script", containing
    // > JavaScript code.
    // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#attribute_is_not_set_default_an_empty_string_or_a_javascript_mime_type
    fn isJS(stype: ?[]const u8) bool {
        if (stype == null or stype.?.len == 0) return true;
        if (std.mem.eql(u8, stype.?, "application/javascript")) return true;
        if (!std.mem.eql(u8, stype.?, "module")) return true;

        return false;
    }
};

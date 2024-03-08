const std = @import("std");
const builtin = @import("builtin");

const Types = @import("root").Types;

const parser = @import("../netsurf.zig");
const Loader = @import("loader.zig").Loader;
const Dump = @import("dump.zig");
const Mime = @import("mime.zig");

const jsruntime = @import("jsruntime");
const Loop = jsruntime.Loop;
const Env = jsruntime.Env;

const apiweb = @import("../apiweb.zig");

const Window = @import("../html/window.zig").Window;
const Walker = @import("../dom/walker.zig").WalkerDepthFirst;

const FetchResult = std.http.Client.FetchResult;

const log = std.log.scoped(.browser);

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
// TODO allow multiple sessions per browser.
pub const Browser = struct {
    session: *Session,

    pub fn init(alloc: std.mem.Allocator, vm: jsruntime.VM) !Browser {
        // We want to ensure the caller initialised a VM, but the browser
        // doesn't use it directly...
        _ = vm;

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
    window: Window,

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
        };

        self.env = try Env.init(self.arena.allocator(), &self.loop);
        try self.env.load(&self.jstypes);

        return self;
    }

    fn deinit(self: *Session) void {
        self.env.deinit();
        self.arena.deinit();

        self.loader.deinit();
        self.loop.deinit();
        self.alloc.destroy(self);
    }

    pub fn createPage(self: *Session) !Page {
        return Page.init(self.alloc, self);
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

    raw_data: ?[]const u8 = null,

    fn init(
        alloc: std.mem.Allocator,
        session: *Session,
    ) Page {
        return Page{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .session = session,
        };
    }

    // reset js env and mem arena.
    pub fn end(self: *Page) void {
        self.session.env.stop();
        // TODO unload document: https://html.spec.whatwg.org/#unloading-documents

        _ = self.arena.reset(.free_all);
    }

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
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

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    pub fn navigate(self: *Page, uri: []const u8) !void {
        const alloc = self.arena.allocator();

        log.debug("starting GET {s}", .{uri});

        // own the url
        if (self.rawuri) |prev| alloc.free(prev);
        self.rawuri = try alloc.dupe(u8, uri);
        self.uri = std.Uri.parse(self.rawuri.?) catch try std.Uri.parseWithoutScheme(self.rawuri.?);

        // TODO handle fragment in url.

        // load the data
        var resp = try self.session.loader.get(alloc, self.uri);
        defer resp.deinit();

        const req = resp.req;

        log.info("GET {any} {d}", .{ self.uri, req.response.status });

        // TODO handle redirection
        if (req.response.status != .ok) {
            log.debug("{?} {d} {s}\n{any}", .{
                req.response.version,
                req.response.status,
                req.response.reason,
                req.response.headers,
            });
            return error.BadStatusCode;
        }

        // TODO handle charset
        // https://html.spec.whatwg.org/#content-type
        const ct = req.response.headers.getFirstValue("Content-Type") orelse {
            // no content type in HTTP headers.
            // TODO try to sniff mime type from the body.
            log.info("no content-type HTTP header", .{});
            return;
        };
        log.debug("header content-type: {s}", .{ct});
        const mime = try Mime.parse(ct);
        if (mime.eql(Mime.HTML)) {
            try self.loadHTMLDoc(req.reader(), mime.charset orelse "utf-8");
        } else {
            log.info("non-HTML document: {s}", .{ct});

            // save the body into the page.
            self.raw_data = try req.reader().readAllAlloc(alloc, 16 * 1024 * 1024);
        }
    }

    // https://html.spec.whatwg.org/#read-html
    fn loadHTMLDoc(self: *Page, reader: anytype, charset: []const u8) !void {
        const alloc = self.arena.allocator();

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

        // https://html.spec.whatwg.org/#read-html

        // start JS env
        // TODO load the js env concurrently with the HTML parsing.
        log.debug("start js env", .{});
        try self.session.env.start(alloc);

        // add global objects
        log.debug("setup global env", .{});
        try self.session.env.bindGlobal(self.session.window);

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
            self.evalScript(e) catch |err| log.warn("evaljs: {any}", .{err});
        }

        // TODO wait for deferred scripts

        // dispatch DOMContentLoaded before the transition to "complete",
        // at the point where all subresources apart from async script elements
        // have loaded.
        // https://html.spec.whatwg.org/#reporting-document-loading-status
        const evt = try parser.eventCreate();
        try parser.eventInit(evt, "DOMContentLoaded", .{ .bubbles = true, .cancelable = true });
        _ = try parser.eventTargetDispatchEvent(parser.toEventTarget(parser.DocumentHTML, html_doc), evt);

        // eval async scripts.
        for (sasync.items) |e| {
            self.evalScript(e) catch |err| log.warn("evaljs: {any}", .{err});
        }

        // TODO wait for async scripts

        // TODO set document.readyState to complete

        // dispatch window.load event
        const loadevt = try parser.eventCreate();
        try parser.eventInit(loadevt, "load", .{});
        _ = try parser.eventTargetDispatchEvent(parser.toEventTarget(Window, &self.session.window), loadevt);
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

        const opt_text = try parser.nodeTextContent(parser.elementToNode(e));
        if (opt_text) |text| {
            // TODO handle charset attribute
            var res = jsruntime.JSResult{};
            try self.session.env.run(alloc, text, "", &res, null);
            defer res.deinit(alloc);

            if (res.success) {
                log.debug("eval inline: {s}", .{res.result});
            } else {
                log.info("eval inline: {s}", .{res.result});
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

        const u = std.Uri.parse(src) catch try std.Uri.parseWithoutScheme(src);
        const ru = try std.Uri.resolve(self.uri, u, false, alloc);

        var fetchres = try self.session.loader.fetch(alloc, ru);
        defer fetchres.deinit();

        log.info("fech script {any}: {d}", .{ ru, fetchres.status });

        if (fetchres.status != .ok) return FetchError.BadStatusCode;

        // TODO check content-type

        // check no body
        if (fetchres.body == null) return FetchError.NoBody;

        var res = jsruntime.JSResult{};
        try self.session.env.run(alloc, fetchres.body.?, src, &res, null);
        defer res.deinit(alloc);

        if (res.success) {
            log.debug("eval remote {s}: {s}", .{ src, res.result });
        } else {
            // In debug mode only, save the file in a temp file.
            if (comptime builtin.mode == .Debug) {
                writeCache(alloc, u.path, fetchres.body.?) catch |e| {
                    log.debug("cache: {any}", .{e});
                };
            }

            log.info("eval remote {s}: {s}", .{ src, res.result });
            return FetchError.JsErr;
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

// writeCache write a cache file in the current dir with the given data.
// Alloc is used to create a temp filename, cleared before returning.
fn writeCache(alloc: std.mem.Allocator, name: []const u8, data: []const u8) !void {
    const fname = try std.mem.concat(alloc, u8, &.{ name, ".cache" });
    defer alloc.free(fname);

    // clear invalid char.
    for (fname, 0..) |c, i| {
        if (!std.ascii.isPrint(c) or std.ascii.isWhitespace(c) or c == '/') {
            fname[i] = '_';
        }
    }

    log.debug("cache {s}", .{fname});

    const f = try std.fs.cwd().createFile(fname, .{ .read = false, .truncate = true });
    defer f.close();

    try f.writeAll(data);
}

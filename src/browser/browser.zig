const std = @import("std");

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
const Walker = @import("../dom/html_collection.zig").WalkerDepthFirst;

const FetchResult = std.http.Client.FetchResult;

const log = std.log.scoped(.browser);

// Browser is an instance of the browser.
// You can create multiple browser instances.
// It contains only one session but initVM() and deinitVM() must be called only
// once per main.
pub const Browser = struct {
    allocator: std.mem.Allocator,
    session: *Session = undefined,

    var vm: jsruntime.VM = undefined;
    pub fn initVM() void {
        vm = jsruntime.VM.init();
    }
    pub fn deinitVM() void {
        vm.deinit();
    }

    pub fn init(allocator: std.mem.Allocator) !Browser {
        return Browser{
            .allocator = allocator,
            .session = try Session.init(allocator, "about:blank"),
        };
    }

    pub fn deinit(self: *Browser) void {
        self.session.deinit();
        self.allocator.destroy(self.session);
    }

    pub fn currentSession(self: *Browser) *Session {
        return self.session;
    }
};

// Session is like a browser's tab.
// It owns the js env and the loader and an allocator arena for all the pages
// of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    uri: []const u8,

    // TODO handle proxy
    loader: Loader = undefined,
    env: Env = undefined,
    loop: Loop = undefined,
    jstypes: [Types.len]usize = undefined,

    window: Window,

    fn init(allocator: std.mem.Allocator, uri: []const u8) !*Session {
        var self = try allocator.create(Session);
        self.* = Session{
            .uri = uri,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .window = Window.create(null),
        };

        const aallocator = self.arena.allocator();

        self.loader = Loader.init(aallocator);
        self.loop = try Loop.init(aallocator);
        self.env = try Env.init(aallocator, &self.loop);

        try self.env.load(&self.jstypes);

        return self;
    }

    fn deinit(self: *Session) void {
        self.loader.deinit();
        self.loop.deinit();
        self.env.deinit();
        self.arena.deinit();
    }

    pub fn createPage(self: *Session) !Page {
        return Page.init(
            self.arena.allocator(),
            &self.loader,
            &self.env,
            &self.window,
        );
    }
};

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
pub const Page = struct {
    allocator: std.mem.Allocator,
    loader: *Loader,
    env: *Env,
    window: *Window,
    doc: ?*parser.Document = null,

    // handle url
    rawuri: ?[]const u8 = null,
    uri: std.Uri = undefined,

    raw_data: ?[]const u8 = null,

    fn init(
        allocator: std.mem.Allocator,
        loader: *Loader,
        env: *Env,
        window: *Window,
    ) Page {
        return Page{
            .allocator = allocator,
            .loader = loader,
            .env = env,
            .window = window,
        };
    }

    pub fn end(self: *Page) void {
        self.env.stop();
        // TODO unload document: https://html.spec.whatwg.org/#unloading-documents
    }

    pub fn deinit(self: *Page) void {
        if (self.raw_data) |s| {
            self.allocator.free(s);
        }
        if (self.raw_data) |s| {
            self.allocator.free(s);
        }
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
        try Dump.htmlFile(self.doc.?, out);
    }

    // spec reference: https://html.spec.whatwg.org/#document-lifecycle
    pub fn navigate(self: *Page, uri: []const u8) !void {
        log.debug("starting GET {s}", .{uri});

        // own the url
        if (self.rawuri) |prev| self.allocator.free(prev);
        self.rawuri = try self.allocator.dupe(u8, uri);
        self.uri = std.Uri.parse(self.rawuri.?) catch try std.Uri.parseWithoutScheme(self.rawuri.?);

        // TODO handle fragment in url.

        // load the data
        var resp = try self.loader.get(self.allocator, self.uri);
        defer resp.deinit();

        const req = resp.req;

        log.info("GET {any} {d}", .{ self.uri, req.response.status });

        // TODO handle redirection
        if (req.response.status != .ok) return error.BadStatusCode;

        // TODO handle charset
        // https://html.spec.whatwg.org/#content-type
        const ct = req.response.headers.getFirstValue("Content-Type") orelse {
            // no content type in HTTP headers.
            // TODO try to sniff mime type from the body.
            log.info("no content-type HTTP header", .{});
            return;
        };
        const mime = try Mime.parse(ct);
        if (mime.eql(Mime.HTML)) {
            // TODO check content-type
            try self.loadHTMLDoc(req.reader());
        } else {
            log.info("non-HTML document: {s}", .{ct});

            // save the body into the page.
            self.raw_data = try req.reader().readAllAlloc(self.allocator, 16 * 1024 * 1024);
        }
    }

    // https://html.spec.whatwg.org/#read-html
    fn loadHTMLDoc(self: *Page, reader: anytype) !void {
        log.debug("parse html", .{});
        // TODO pass an encoding detected from HTTP headers.
        const html_doc = try parser.documentHTMLParse(reader, "UTF-8");
        const doc = parser.documentHTMLToDocument(html_doc);

        // save a document's pointer in the page.
        self.doc = doc;

        // TODO set document.readyState to interactive
        // https://html.spec.whatwg.org/#reporting-document-loading-status

        // TODO inject the URL to the document including the fragment.
        // TODO set the referrer to the document.

        self.window.replaceDocument(doc);

        // https://html.spec.whatwg.org/#read-html

        // start JS env
        log.debug("start js env", .{});
        try self.env.start(self.allocator);

        // add global objects
        log.debug("setup global env", .{});
        try self.env.addObject(self.window, "window");
        try self.env.addObject(self.window, "self");
        try self.env.addObject(html_doc, "document");

        // browse the DOM tree to retrieve scripts

        // sasync stores scripts which can be run asynchronously.
        // for now they are just run after the non-async one in order to
        // dispatch DOMContentLoaded the sooner as possible.
        var sasync = std.ArrayList(*parser.Element).init(self.allocator);
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

        // TODO dispatch DOMContentLoaded before the transition to "complete",
        // at the point where all subresources apart from async script elements
        // have loaded.
        // https://html.spec.whatwg.org/#reporting-document-loading-status

        // eval async scripts.
        for (sasync.items) |e| {
            self.evalScript(e) catch |err| log.warn("evaljs: {any}", .{err});
        }

        // TODO wait for async scripts

        // TODO set document.readyState to complete
    }

    // evalScript evaluates the src in priority.
    // if no src is present, we evaluate the text source.
    // https://html.spec.whatwg.org/multipage/scripting.html#script-processing-model
    fn evalScript(self: *Page, e: *parser.Element) !void {
        // https://html.spec.whatwg.org/multipage/webappapis.html#fetch-a-classic-script
        const opt_src = try parser.elementGetAttribute(e, "src");
        if (opt_src) |src| {
            log.debug("starting GET {s}", .{src});

            const u = std.Uri.parse(src) catch try std.Uri.parseWithoutScheme(src);
            const ru = try std.Uri.resolve(self.uri, u, false, self.allocator);

            var fetchres = try self.loader.fetch(self.allocator, ru);
            defer fetchres.deinit();

            log.info("GET {any}: {d}", .{ ru, fetchres.status });

            if (fetchres.status != .ok) {
                return error.BadStatusCode;
            }

            // TODO check content-type

            // check no body
            // TODO If el's result is null, then fire an event named error at
            // el, and return.
            if (fetchres.body == null) return;

            var res = jsruntime.JSResult{};
            try self.env.run(self.allocator, fetchres.body.?, src, &res, null);
            defer res.deinit(self.allocator);

            if (res.success) {
                log.debug("eval remote {s}: {s}", .{ src, res.result });
            } else {
                log.info("eval remote {s}: {s}", .{ src, res.result });
            }

            // TODO If el's from an external file is true, then fire an event
            // named load at el.

            return;
        }

        const opt_text = try parser.nodeTextContent(parser.elementToNode(e));
        if (opt_text) |text| {
            // TODO handle charset attribute
            var res = jsruntime.JSResult{};
            try self.env.run(self.allocator, text, "", &res, null);
            defer res.deinit(self.allocator);

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

    // > type
    // > Attribute is not set (default), an empty string, or a JavaScript MIME
    // > type indicates that the script is a "classic script", containing
    // > JavaScript code.
    // https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script#attribute_is_not_set_default_an_empty_string_or_a_javascript_mime_type
    fn isJS(stype: ?[]const u8) bool {
        return stype == null or stype.?.len == 0 or std.mem.eql(u8, stype.?, "application/javascript") or !std.mem.eql(u8, stype.?, "module");
    }
};

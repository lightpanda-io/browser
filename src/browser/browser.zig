const std = @import("std");

const parser = @import("../netsurf.zig");
const Loader = @import("loader.zig").Loader;

const jsruntime = @import("jsruntime");
const Loop = jsruntime.Loop;
const Env = jsruntime.Env;
const TPL = jsruntime.TPL;

const apiweb = @import("../apiweb.zig");
const apis = jsruntime.compile(apiweb.Interfaces);

const Window = @import("../nav/window.zig").Window;

const log = std.log.scoped(.lpd_browser);

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
    tpls: [apis.len]TPL = undefined,

    // TODO handle proxy
    loader: Loader = undefined,
    env: Env = undefined,
    loop: Loop = undefined,

    fn init(allocator: std.mem.Allocator, uri: []const u8) !*Session {
        var self = try allocator.create(Session);
        self.* = Session{
            .uri = uri,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };

        const aallocator = self.arena.allocator();

        self.loader = Loader.init(aallocator);
        self.loop = try Loop.init(aallocator);
        self.env = try Env.init(aallocator, &self.loop);

        try self.env.load(apis, &self.tpls);

        return self;
    }

    fn deinit(self: *Session) void {
        self.loader.deinit();
        self.loop.deinit();
        self.env.deinit();
        self.arena.deinit();
    }

    pub fn createPage(self: *Session) !Page {
        return Page.init(self.arena.allocator(), &self.loader, &self.env);
    }
};

// Page navigates to an url.
// You can navigates multiple urls with the same page, but you have to call
// end() to stop the previous navigation before starting a new one.
pub const Page = struct {
    allocator: std.mem.Allocator,
    loader: *Loader,
    env: *Env,

    fn init(allocator: std.mem.Allocator, loader: *Loader, env: *Env) Page {
        return Page{
            .allocator = allocator,
            .loader = loader,
            .env = env,
        };
    }

    pub fn end(self: *Page) void {
        self.env.stop();
    }

    pub fn navigate(self: *Page, uri: []const u8) !void {
        log.debug("starting GET {s}", .{uri});

        // load the data
        var result = try self.loader.fetch(self.allocator, uri);
        defer result.deinit();

        log.info("GET {s} {d}", .{ uri, result.status });

        // TODO handle redirection
        if (result.status != .ok) return error.BadStatusCode;

        if (result.body == null) return error.NoBody;

        // TODO check content-type

        // TODO handle charset

        // document
        log.debug("parse html", .{});
        const html_doc = try parser.documentHTMLParseFromStrAlloc(self.allocator, result.body.?);
        const doc = parser.documentHTMLToDocument(html_doc);

        // start JS env
        log.debug("start js env", .{});
        try self.env.start(self.allocator, apis);

        // add global objects
        log.debug("setup global env", .{});
        const window = Window.create(doc, null);
        _ = window;
        // TODO should'nt we share the same pointer between instances of window?
        // try js_env.addObject(apis, window, "self");
        // try js_env.addObject(apis, window, "window");
        try self.env.addObject(apis, doc, "document");
    }
};

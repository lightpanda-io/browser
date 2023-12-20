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

pub const Browser = struct {
    allocator: std.mem.Allocator,
    session: Session = undefined,

    var vm: jsruntime.VM = undefined;
    pub fn initVM() void {
        vm = jsruntime.VM.init();
    }
    pub fn deinitVM() void {
        vm.deinit();
    }

    pub fn init(allocator: std.mem.Allocator) Browser {
        var b = Browser{ .allocator = allocator };
        b.session = try b.createSession(null);

        return b;
    }

    pub fn deinit(self: *Browser) void {
        var session = self.session;
        session.deinit();
    }

    pub fn currentSession(self: *Browser) *Session {
        return &self.session;
    }

    fn createSession(self: *Browser, uri: ?[]const u8) !Session {
        return Session.init(self.allocator, uri orelse "about:blank");
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    uri: []const u8,
    // TODO handle proxy
    loader: Loader,

    fn init(allocator: std.mem.Allocator, uri: []const u8) Session {
        return Session{
            .allocator = allocator,
            .uri = uri,
            .loader = Loader.init(allocator),
        };
    }

    fn deinit(self: *Session) void {
        self.loader.deinit();
    }

    pub fn createPage(self: *Session) !Page {
        return Page.init(self);
    }
};

pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    session: *Session,
    env: Env,

    fn init(session: *Session) Page {
        return Page{
            .session = session,
            .arena = std.heap.ArenaAllocator.init(session.allocator),
            .env = undefined,
        };
    }

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
    }

    pub fn navigate(self: *Page, uri: []const u8) !void {
        const allocator = self.arena.allocator();

        log.debug("starting GET {s}", .{uri});

        // load the data
        var result = try self.session.loader.fetch(allocator, uri);
        defer result.deinit();

        log.info("GET {s} {d}", .{ uri, result.status });

        // TODO handle redirection
        if (result.status != .ok) return error.BadStatusCode;

        if (result.body == null) return error.NoBody;

        // TODO check content-type

        // TODO handle charset

        // document
        log.debug("parse html", .{});
        const html_doc = try parser.documentHTMLParseFromStrAlloc(allocator, result.body.?);
        const doc = parser.documentHTMLToDocument(html_doc);

        log.debug("init loop", .{});
        var loop = try Loop.init(allocator);
        defer loop.deinit();

        // create JS env
        log.debug("init js env", .{});
        self.env = try Env.init(allocator, &loop);
        defer self.env.deinit();

        // load APIs in JS env
        log.debug("load js apis", .{});
        var tpls: [apis.len]TPL = undefined;
        try self.env.load(apis, &tpls);

        // start JS env
        log.debug("start js env", .{});
        try self.env.start(allocator, apis);
        defer self.env.stop();

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

test "create page" {
    const allocator = std.testing.allocator;
    var browser = Browser.init(allocator);
    defer browser.deinit();

    var page = try browser.currentSession().createPage();
    defer page.deinit();
}

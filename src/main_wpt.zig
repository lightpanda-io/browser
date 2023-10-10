const std = @import("std");

const parser = @import("netsurf.zig");
const jsruntime = @import("jsruntime");

const public = @import("jsruntime");
const TPL = public.TPL;
const Env = public.Env;
const Loop = public.Loop;

const DOM = @import("dom.zig");
const HTMLElem = @import("html/elements.zig");

const wpt_dir = "tests/wpt";

// generate APIs
const apis = jsruntime.compile(DOM.Interfaces);

// FileLoader loads files content from the filesystem.
const FileLoader = struct {
    files: std.StringHashMap([]const u8) = undefined,
    path: []const u8,
    alloc: std.mem.Allocator,

    const Self = @This();

    fn new(alloc: std.mem.Allocator, path: []const u8) Self {
        return Self{
            .path = path,
            .alloc = alloc,
            .files = std.StringHashMap([]const u8).init(alloc),
        };
    }
    fn get(self: *Self, name: []const u8) ![]const u8 {
        if (!self.files.contains(name)) {
            try self.load(name);
        }
        return self.files.get(name).?;
    }
    fn load(self: *Self, name: []const u8) !void {
        const filename = try std.mem.concat(self.alloc, u8, &.{ self.path, name });
        defer self.alloc.free(filename);
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const content = try file.readToEndAlloc(self.alloc, file_size);
        const namedup = try self.alloc.dupe(u8, name);
        try self.files.put(namedup, content);
    }
    fn deinit(self: *Self) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }
};

// TODO For now the WPT tests run is specific to WPT.
// It manually load js framwork libs, and run the first script w/ js content in
// the HTML page.
// Once browsercore will have the html loader, it would be useful to refacto
// this test to use it.
pub fn main() !void {
    std.debug.print("Running WPT test suite\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // initialize VM JS lib.
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // prepare libraries to load on each test case.
    var loader = FileLoader.new(alloc, "tests/wpt");
    defer loader.deinit();

    // browse the dir to get the tests dynamically.
    var list = std.ArrayList([]const u8).init(alloc);
    try findWPTTests(alloc, wpt_dir, &list);
    defer {
        for (list.items) |tc| {
            alloc.free(tc);
        }
        list.deinit();
    }

    var run: usize = 0;
    var failures: usize = 0;
    for (list.items) |tc| {
        run += 1;

        // create an arena and deinit it for each test case.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        // TODO I don't use testing.expect here b/c I want to execute all the
        // tests. And testing.expect stops running test in the first failure.
        const res = runWPT(&arena, tc, &loader) catch |err| {
            std.debug.print("FAIL\t{s}\n{any}\n", .{ tc, err });
            failures += 1;
            continue;
        };
        // no need to call res.deinit() thanks to the arena allocator.

        if (!res.success) {
            std.debug.print("FAIL\t{s}\n{s}\n", .{ tc, res.stack orelse res.result });
            failures += 1;
            continue;
        }
        if (!std.mem.eql(u8, res.result, "Pass")) {
            std.debug.print("FAIL\t{s}\n{s}\n", .{ tc, res.stack orelse res.result });
            failures += 1;
            continue;
        }

        std.debug.print("PASS\t{s}\n", .{tc});
    }

    if (failures > 0) {
        std.debug.print("{d}/{d} tests failures\n", .{ failures, run });
        std.os.exit(1);
    }
}

// runWPT parses the given HTML file, starts a js env and run the first script
// tags containing javascript sources.
// It loads first the js libs files.
fn runWPT(arena: *std.heap.ArenaAllocator, f: []const u8, loader: *FileLoader) !jsruntime.JSResult {
    const alloc = arena.allocator();

    // document
    const htmldoc = try parser.documentHTMLParseFromFileAlloc(alloc, f);
    var doc = parser.documentHTMLToDocument(htmldoc);

    // create JS env
    var loop = try Loop.init(alloc);
    defer loop.deinit();
    var js_env = try Env.init(arena, &loop);
    defer js_env.deinit();

    // load APIs in JS env
    var tpls: [apis.len]TPL = undefined;
    try js_env.load(apis, &tpls);

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    // add document object
    try js_env.addObject(apis, doc, "document");

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    var res = jsruntime.JSResult{};
    var cbk_res = jsruntime.JSResult{
        .success = true,
        // assume that the return value of the successfull callback is "undefined"
        .result = "undefined",
    };

    const init =
        \\window.listeners = [];
        \\window.document = document;
        \\window.parent = window;
        \\window.addEventListener = function (type, listener, options) {
        \\  window.listeners.push({type: type, listener: listener, options: options});
        \\};
        \\window.dispatchEvent = function (event) {
        \\  len = window.listeners.length;
        \\  for (var i = 0; i < len; i++) {
        \\      if (window.listeners[i].type == event.target) {
        \\          window.listeners[i].listener(event);
        \\      }
        \\  }
        \\  return true;
        \\};
        \\window.removeEventListener = function () {};
    ;
    try js_env.run(alloc, init, "init", &res, &cbk_res);
    if (!res.success) {
        return res;
    }

    // TODO load <script src> attributes instead of the static list.
    try js_env.run(alloc, try loader.get("/resources/testharness.js"), "testharness.js", &res, &cbk_res);
    if (!res.success) {
        return res;
    }
    try js_env.run(alloc, try loader.get("/resources/testharnessreport.js"), "testharnessreport.js", &res, &cbk_res);
    if (!res.success) {
        return res;
    }

    // loop hover the scripts.
    const scripts = parser.documentGetElementsByTagName(doc, "script");
    const slen = parser.nodeListLength(scripts);
    for (0..slen) |i| {
        const s = parser.nodeListItem(scripts, @intCast(i)).?;

        // search only script tag containing text a child.
        const text = parser.nodeFirstChild(s) orelse continue;

        const src = parser.nodeTextContent(text).?;
        try js_env.run(alloc, src, "", &res, &cbk_res);

        // return the first failure.
        if (!res.success) {
            return res;
        }
    }

    // Mark tests as ready to run.
    try js_env.run(alloc, "window.dispatchEvent({target: 'load'});", "ready", &res, &cbk_res);
    if (!res.success) {
        return res;
    }

    // Check the final test status.
    try js_env.run(alloc, "report.status;", "teststatus", &res, &cbk_res);
    if (!res.success) {
        return res;
    }

    // If the test failed, return detailed logs intead of the simple status.
    if (!std.mem.eql(u8, res.result, "Pass")) {
        try js_env.run(alloc, "report.log", "teststatus", &res, &cbk_res);
    }

    // return the final result.
    return res;
}

// browse the path to find the tests list.
fn findWPTTests(allocator: std.mem.Allocator, path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = try std.fs.cwd().openIterableDir(path, .{ .no_follow = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, entry.basename, ".html")) {
            continue;
        }

        try list.append(try std.fs.path.join(allocator, &.{ path, entry.path }));
    }
}

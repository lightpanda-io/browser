const std = @import("std");

const parser = @import("netsurf.zig");
const jsruntime = @import("jsruntime");

const TPL = jsruntime.TPL;
const Env = jsruntime.Env;
const Loop = jsruntime.Loop;

const DOM = @import("dom.zig");
const HTMLElem = @import("html/elements.zig");

const wpt_dir = "tests/wpt";

// generate APIs
const apis = jsruntime.compile(DOM.Interfaces);

// FileLoader loads files content from the filesystem.
const FileLoader = struct {
    const FilesMap = std.StringHashMap([]const u8);

    files: FilesMap,
    path: []const u8,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, path: []const u8) FileLoader {
        const files = FilesMap.init(alloc);

        return FileLoader{
            .path = path,
            .alloc = alloc,
            .files = files,
        };
    }
    fn get(self: *FileLoader, name: []const u8) ![]const u8 {
        if (!self.files.contains(name)) {
            try self.load(name);
        }
        return self.files.get(name).?;
    }
    fn load(self: *FileLoader, name: []const u8) !void {
        const filename = try std.mem.concat(self.alloc, u8, &.{ self.path, name });
        defer self.alloc.free(filename);
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const content = try file.readToEndAlloc(self.alloc, file_size);
        const namedup = try self.alloc.dupe(u8, name);
        try self.files.put(namedup, content);
    }
    fn deinit(self: *FileLoader) void {
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

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const filter = args[1..];

    // initialize VM JS lib.
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // prepare libraries to load on each test case.
    var loader = FileLoader.init(alloc, "tests/wpt");
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
        if (filter.len > 0) {
            var match = false;
            for (filter) |f| {
                if (std.mem.startsWith(u8, tc, f)) {
                    match = true;
                    break;
                }
                if (std.mem.endsWith(u8, tc, f)) {
                    match = true;
                    break;
                }
            }
            if (!match) {
                continue;
            }
        }

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
    const html_doc = try parser.documentHTMLParseFromFileAlloc(alloc, f);
    const doc = parser.documentHTMLToDocument(html_doc);

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
    try js_env.addObject(apis, html_doc, "document");

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    // thanks to the arena, we don't need to deinit res.
    var res: jsruntime.JSResult = undefined;

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
    res = try evalJS(js_env, alloc, init, "init");
    if (!res.success) {
        return res;
    }

    // TODO load <script src> attributes instead of the static list.
    res = try evalJS(js_env, alloc, try loader.get("/resources/testharness.js"), "testharness.js");
    if (!res.success) {
        return res;
    }
    res = try evalJS(js_env, alloc, try loader.get("/resources/testharnessreport.js"), "testharnessreport.js");
    if (!res.success) {
        return res;
    }

    // loop hover the scripts.
    const scripts = parser.documentGetElementsByTagName(doc, "script");
    const slen = parser.nodeListLength(scripts);
    for (0..slen) |i| {
        const s = parser.nodeListItem(scripts, @intCast(i)).?;

        const src = parser.nodeTextContent(s).?;
        res = try evalJS(js_env, alloc, src, "");

        // return the first failure.
        if (!res.success) {
            return res;
        }
    }

    // Mark tests as ready to run.
    res = try evalJS(js_env, alloc, "window.dispatchEvent({target: 'load'});", "ready");
    if (!res.success) {
        return res;
    }

    // Check the final test status.
    res = try evalJS(js_env, alloc, "report.status;", "teststatus");
    if (!res.success) {
        return res;
    }

    // If the test failed, return detailed logs intead of the simple status.
    if (!std.mem.eql(u8, res.result, "Pass")) {
        return try evalJS(js_env, alloc, "report.log", "teststatus");
    }

    // return the final result.
    return res;
}

fn evalJS(env: jsruntime.Env, alloc: std.mem.Allocator, script: []const u8, name: ?[]const u8) !jsruntime.JSResult {
    var res = jsruntime.JSResult{};
    try env.run(alloc, script, name, &res, null);
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

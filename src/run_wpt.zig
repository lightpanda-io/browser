const std = @import("std");

const parser = @import("netsurf.zig");
const jsruntime = @import("jsruntime");

const public = @import("jsruntime");
const API = public.API;
const TPL = public.TPL;
const Env = public.Env;
const Loop = public.Loop;

const DOM = @import("dom.zig");
const HTMLElem = @import("html/elements.zig");

const wpt_dir = "tests/wpt";

fn readFile(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    return file.readToEndAlloc(allocator, file_size);
}

// generate APIs
const apis = jsruntime.compile(DOM.Interfaces);

// TODO For now the WPT tests run is specific to WPT.
// It manually load js framwork libs, and run the first script w/ js content in
// the HTML page.
// Once browsercore will have the html loader, it would be useful to refacto
// this test to use it.
test {
    std.debug.print("Running WPT test suite\n", .{});

    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);
    const alloc = bench_alloc.allocator();

    // initialize VM JS lib.
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // prepare libraries to load on each test case.
    var libs: [2][]const u8 = undefined;
    // read testharness.js content
    libs[0] = try readFile(alloc, "tests/wpt/resources/testharness.js");
    defer alloc.free(libs[0]);

    // read testharnessreport.js content
    libs[1] = try readFile(alloc, "tests/wpt/resources/testharnessreport.js");
    defer alloc.free(libs[1]);

    // browse the dir to get the tests dynamically.
    const list = try findWPTTests(alloc, wpt_dir);
    defer list.deinit();

    const testcases: [][]const u8 = list.items;

    var failures: usize = 0;
    for (testcases) |tc| {
        // create an arena and deinit it for each test case.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        // TODO I don't use testing.expect here b/c I want to execute all the
        // tests. And testing.expect stops running test in the first failure.
        std.debug.print("{s}\t\t", .{tc});

        const res = runWPT(&arena, tc, libs[0..]) catch |err| {
            std.debug.print("ERR\n\t> {any}\n", .{err});
            failures += 1;
            continue;
        };

        if (!res.success) {
            std.debug.print("ERR\n\t> {s}\n", .{res.result});
            failures += 1;
            continue;
        }
        std.debug.print("OK\n", .{});
    }

    if (failures > 0) {
        std.debug.print("{d}/{d} tests failures\n", .{ failures, testcases.len });
    }
    try std.testing.expect(failures == 0);
}

// runWPT parses the given HTML file, starts a js env and run the first script
// tags containing javascript sources.
// It loads first the js libs files.
fn runWPT(arena: *std.heap.ArenaAllocator, f: []const u8, libs: []const []const u8) !jsruntime.JSResult {
    const alloc = arena.allocator();

    // document
    const htmldoc = try parser.documentHTMLParse(alloc, f);
    const doc = parser.documentHTMLToDocument(htmldoc);

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

    var res = jsruntime.JSResult{};
    var cbk_res = jsruntime.JSResult{
        .success = true,
        // assume that the return value of the successfull callback is "undefined"
        .result = "undefined",
    };

    // execute libs
    for (libs) |lib| {
        try js_env.run(alloc, lib, "", &res, &cbk_res);
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

        return res;
    }

    return error.EmptyTest;
}

// browse the path to find the tests list.
fn findWPTTests(allocator: std.mem.Allocator, path: []const u8) !*std.ArrayList([]const u8) {
    var dir = try std.fs.cwd().openIterableDir(path, .{ .no_follow = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var tc = std.ArrayList([]const u8).init(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, entry.basename, ".html")) {
            continue;
        }

        try tc.append(try std.fs.path.join(allocator, &.{ path, entry.path }));
    }

    return &tc;
}

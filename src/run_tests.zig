const std = @import("std");

const jsruntime = @import("jsruntime");
const generate = @import("generate.zig");

const parser = @import("netsurf.zig");
const DOM = @import("dom.zig");
const docTestExecFn = @import("html/document.zig").testExecFn;
const nodeTestExecFn = @import("dom/node.zig").testExecFn;

var doc: *parser.DocumentHTML = undefined;

fn testsExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    // add document object
    try js_env.addObject(apis, doc, "document");

    // run tests
    try docTestExecFn(alloc, js_env, apis);
    try nodeTestExecFn(alloc, js_env, apis);
}

test {
    std.debug.print("\n \n", .{});

    // generate tests
    try generate.tests();

    // generate APIs
    const apis = jsruntime.compile(DOM.Interfaces);

    // document
    var f = "test.html".*;
    doc = parser.documentHTMLParse(&f);

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);
    var arena_alloc = std.heap.ArenaAllocator.init(bench_alloc.allocator());
    defer arena_alloc.deinit();

    try jsruntime.loadEnv(&arena_alloc, testsExecFn, apis);
}

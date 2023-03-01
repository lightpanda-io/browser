const std = @import("std");

const jsruntime = @import("jsruntime");

const DOM = @import("dom.zig");
const document = @import("dom/document.zig");
const element = @import("dom/element.zig");

const html = @import("html.zig").html;

var doc: DOM.HTMLDocument = undefined;

fn testsExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {

    // start JS env
    js_env.start();
    defer js_env.stop();

    // add document object
    try js_env.addObject(apis, doc, "document");

    // run tests
    try document.testExecFn(js_env, apis);
}

test {
    // generate APIs
    const apis = jsruntime.compile(DOM.Interfaces);

    // document
    doc = DOM.HTMLDocument.init();
    defer doc.deinit();
    try doc.parse(html);

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);
    var arena_alloc = std.heap.ArenaAllocator.init(bench_alloc.allocator());
    defer arena_alloc.deinit();

    try jsruntime.loadEnv(&arena_alloc, testsExecFn, apis);
}

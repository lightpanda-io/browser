const std = @import("std");

const jsruntime = @import("jsruntime");
const generate = @import("generate.zig");

const parser = @import("netsurf.zig");
const DOM = @import("dom.zig");

const docTestExecFn = @import("html/document.zig").testExecFn;
const nodeTestExecFn = @import("dom/node.zig").testExecFn;
const characterDataTestExecFn = @import("dom/character_data.zig").testExecFn;
const textTestExecFn = @import("dom/text.zig").testExecFn;

var doc: *parser.DocumentHTML = undefined;

fn testExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
    comptime execFn: jsruntime.ContextExecFn,
) !void {

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    // document
    doc = try parser.documentHTMLParseFromFileAlloc(std.testing.allocator, "test.html");
    defer parser.documentHTMLClose(doc);

    // add document object
    try js_env.addObject(apis, doc, "document");

    // run test
    try execFn(alloc, js_env, apis);
}

fn testsAllExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {
    const testFns = [_]jsruntime.ContextExecFn{
        docTestExecFn,
        nodeTestExecFn,
        characterDataTestExecFn,
        textTestExecFn,
    };

    inline for (testFns) |testFn| {
        try testExecFn(alloc, js_env, apis, testFn);
    }
}

test {
    std.debug.print("\n \n", .{});

    // generate tests
    try generate.tests();

    // generate APIs
    const apis = jsruntime.compile(DOM.Interfaces);

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);
    var arena_alloc = std.heap.ArenaAllocator.init(bench_alloc.allocator());
    defer arena_alloc.deinit();

    try jsruntime.loadEnv(&arena_alloc, testsAllExecFn, apis);
}

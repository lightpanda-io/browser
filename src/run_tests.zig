const std = @import("std");

const jsruntime = @import("jsruntime");
const generate = @import("generate.zig");

const parser = @import("netsurf.zig");
const DOM = @import("dom.zig");

const documentTestExecFn = @import("dom/document.zig").testExecFn;
const HTMLDocumentTestExecFn = @import("html/document.zig").testExecFn;
const nodeTestExecFn = @import("dom/node.zig").testExecFn;
const characterDataTestExecFn = @import("dom/character_data.zig").testExecFn;
const textTestExecFn = @import("dom/text.zig").testExecFn;
const elementTestExecFn = @import("dom/element.zig").testExecFn;
const HTMLCollectionTestExecFn = @import("dom/html_collection.zig").testExecFn;
const DOMExceptionTestExecFn = @import("dom/exceptions.zig").testExecFn;
const DOMImplementationExecFn = @import("dom/implementation.zig").testExecFn;
const NamedNodeMapExecFn = @import("dom/namednodemap.zig").testExecFn;
const DOMTokenListExecFn = @import("dom/token_list.zig").testExecFn;
const NodeListTestExecFn = @import("dom/nodelist.zig").testExecFn;

var doc: *parser.DocumentHTML = undefined;

fn testExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
    comptime execFn: jsruntime.ContextExecFn,
) !void {

    // start JS env
    try js_env.start(alloc, apis);
    defer js_env.stop();

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    // document
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParseFromFile(file);
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

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
        documentTestExecFn,
        HTMLDocumentTestExecFn,
        nodeTestExecFn,
        characterDataTestExecFn,
        textTestExecFn,
        elementTestExecFn,
        HTMLCollectionTestExecFn,
        DOMExceptionTestExecFn,
        DOMImplementationExecFn,
        NamedNodeMapExecFn,
        DOMTokenListExecFn,
        NodeListTestExecFn,
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
    const apis = comptime jsruntime.compile(DOM.Interfaces);

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);
    var arena_alloc = std.heap.ArenaAllocator.init(bench_alloc.allocator());
    defer arena_alloc.deinit();

    try jsruntime.loadEnv(&arena_alloc, testsAllExecFn, apis);
}

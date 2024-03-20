const std = @import("std");
const builtin = @import("builtin");

const jsruntime = @import("jsruntime");
const generate = @import("generate.zig");

const setCAllocator = @import("calloc.zig").setCAllocator;
const parser = @import("netsurf.zig");
const apiweb = @import("apiweb.zig");
const Window = @import("html/window.zig").Window;
const xhr = @import("xhr/xhr.zig");

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
const AttrTestExecFn = @import("dom/attribute.zig").testExecFn;
const EventTargetTestExecFn = @import("dom/event_target.zig").testExecFn;
const EventTestExecFn = @import("events/event.zig").testExecFn;
const XHRTestExecFn = xhr.testExecFn;
const ProgressEventTestExecFn = @import("xhr/progress_event.zig").testExecFn;

pub const Types = jsruntime.reflect(apiweb.Interfaces);

var doc: *parser.DocumentHTML = undefined;

fn testExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime execFn: jsruntime.ContextExecFn,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    // document
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParse(file.reader(), "UTF-8");
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

    // add document object
    try js_env.addObject(doc, "document");

    // run test
    try execFn(alloc, js_env);
}

fn testsAllExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
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
        AttrTestExecFn,
        EventTargetTestExecFn,
        EventTestExecFn,
        XHRTestExecFn,
        ProgressEventTestExecFn,
    };

    inline for (testFns) |testFn| {
        try testExecFn(alloc, js_env, testFn);
        _ = c_arena.reset(.retain_capacity);
    }
}

var c_arena: std.heap.ArenaAllocator = undefined;

pub fn main() !void {
    std.debug.print("\n", .{});

    c_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer c_arena.deinit();
    setCAllocator(c_arena.allocator());

    for (builtin.test_functions) |test_fn| {
        try test_fn.func();
        std.debug.print("{s}\tOK\n", .{test_fn.name});
    }
}

test {
    const TestAsync = @import("async/test.zig");
    std.testing.refAllDecls(TestAsync);
}

test "jsruntime" {
    // generate tests
    try generate.tests();

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);
    var arena_alloc = std.heap.ArenaAllocator.init(bench_alloc.allocator());
    defer arena_alloc.deinit();

    try jsruntime.loadEnv(&arena_alloc, testsAllExecFn);
}

test "DocumentHTMLParseFromStr" {
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    const str = try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(u32));
    defer std.testing.allocator.free(str);

    doc = try parser.documentHTMLParseFromStr(str);
    parser.documentHTMLClose(doc) catch {};
}

// https://github.com/lightpanda-io/libdom/issues/4
test "bug document html parsing #4" {
    const file = try std.fs.cwd().openFile("tests/html/bug-html-parsing-4.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParse(file.reader(), "UTF-8");
    parser.documentHTMLClose(doc) catch {};
}

const dump = @import("browser/dump.zig");
test "run browser tests" {
    // const out = std.io.getStdOut();
    const out = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer out.close();

    try dump.HTMLFileTestFn(out);
}

test "XMLHttpRequest.validMethod" {
    // valid methods
    for ([_][]const u8{ "get", "GET", "head", "HEAD" }) |tc| {
        _ = try xhr.XMLHttpRequest.validMethod(tc);
    }

    // forbidden
    for ([_][]const u8{ "connect", "CONNECT" }) |tc| {
        try std.testing.expectError(parser.DOMError.Security, xhr.XMLHttpRequest.validMethod(tc));
    }

    // syntax
    for ([_][]const u8{ "foo", "BAR" }) |tc| {
        try std.testing.expectError(parser.DOMError.Syntax, xhr.XMLHttpRequest.validMethod(tc));
    }
}

test "Window is a libdom event target" {
    var window = Window.create(null);

    const event = try parser.eventCreate();
    try parser.eventInit(event, "foo", .{});

    const et = @as(*parser.EventTarget, @ptrCast(&window));
    _ = try parser.eventTargetDispatchEvent(et, event);
}

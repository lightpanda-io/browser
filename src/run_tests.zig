const std = @import("std");
const builtin = @import("builtin");

const jsruntime = @import("jsruntime");
const generate = @import("generate.zig");
const pretty = @import("pretty");

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

    // document
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParse(file.reader(), "UTF-8");
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

    // alias global as self and window
    var window = Window.create(null);
    window.replaceDocument(doc);
    try js_env.bindGlobal(window);

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
    }
}

const usage =
    \\usage: test [options]
    \\  Run the tests. By default the command will run both js and unit tests.
    \\
    \\  -h, --help       Print this help message and exit.
    \\  --browser        run only browser js tests
    \\  --unit           run only js unit tests
    \\  --json           bench result is formatted in JSON.
    \\                   only browser tests are benchmarked.
    \\
;

// Out list all the ouputs handled by benchmark result and written on stdout.
const Out = enum {
    text,
    json,
};

// Which tests must be run.
const Run = enum {
    all,
    browser,
    unit,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(gpa_alloc);
    defer args.deinit();

    // ignore the exec name.
    _ = args.next().?;

    var out: Out = .text;
    var run: Run = .all;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.io.getStdErr().writer().print(usage, .{});
            std.os.exit(0);
        }
        if (std.mem.eql(u8, "--json", arg)) {
            out = .json;
            continue;
        }
        if (std.mem.eql(u8, "--browser", arg)) {
            run = .browser;
            continue;
        }
        if (std.mem.eql(u8, "--unit", arg)) {
            run = .unit;
            continue;
        }
    }

    // run js tests
    if (run == .all or run == .browser) try run_js(out);

    // run standard unit tests.
    if (run == .all or run == .unit) {
        std.debug.print("\n", .{});
        for (builtin.test_functions) |test_fn| {
            try test_fn.func();
            std.debug.print("{s}\tOK\n", .{test_fn.name});
        }
    }
}

// Run js test and display the output depending of the output parameter.
fn run_js(out: Out) !void {
    var bench_alloc = jsruntime.bench_allocator(std.testing.allocator);

    const start = try std.time.Instant.now();

    // run js exectuion tests
    try testJSRuntime(bench_alloc.allocator());

    const duration = std.time.Instant.since(try std.time.Instant.now(), start);
    const stats = bench_alloc.stats();

    // get and display the results
    if (out == .json) {
        const res = [_]struct {
            name: []const u8,
            bench: struct {
                duration: u64,

                alloc_nb: usize,
                realloc_nb: usize,
                alloc_size: usize,
            },
        }{
            .{ .name = "browser", .bench = .{
                .duration = duration,
                .alloc_nb = stats.alloc_nb,
                .realloc_nb = stats.realloc_nb,
                .alloc_size = stats.alloc_size,
            } },
        };

        try std.json.stringify(res, .{ .whitespace = .indent_2 }, std.io.getStdOut().writer());
        return;
    }

    // display console result by default
    const dur = pretty.Measure{ .unit = "ms", .value = duration / ms };
    const size = pretty.Measure{ .unit = "kb", .value = stats.alloc_size / kb };

    // benchmark table
    const row_shape = .{ []const u8, pretty.Measure, u64, u64, pretty.Measure };
    const table = try pretty.GenerateTable(1, row_shape, pretty.TableConf{ .margin_left = "  " });
    const header = .{ "FUNCTION", "DURATION", "ALLOCATIONS (nb)", "RE-ALLOCATIONS (nb)", "HEAP SIZE" };
    var t = table.init("Benchmark browsercore 🚀", header);
    try t.addRow(.{ "browser", dur, stats.alloc_nb, stats.realloc_nb, size });
    try t.render(std.io.getStdOut().writer());
}

const kb = 1024;
const ms = std.time.ns_per_ms;

test {
    const asyncTest = @import("async/test.zig");
    std.testing.refAllDecls(asyncTest);

    const dumpTest = @import("browser/dump.zig");
    std.testing.refAllDecls(dumpTest);

    const cssTest = @import("css/css.zig");
    std.testing.refAllDecls(cssTest);

    const cssParserTest = @import("css/parser.zig");
    std.testing.refAllDecls(cssParserTest);

    const cssMatchTest = @import("css/match_test.zig");
    std.testing.refAllDecls(cssMatchTest);

    const cssLibdomTest = @import("css/libdom_test.zig");
    std.testing.refAllDecls(cssLibdomTest);
}

fn testJSRuntime(alloc: std.mem.Allocator) !void {
    // generate tests
    try generate.tests();

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
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

test "Window is a libdom event target" {
    var window = Window.create(null);

    const event = try parser.eventCreate();
    try parser.eventInit(event, "foo", .{});

    const et = parser.toEventTarget(Window, &window);
    _ = try parser.eventTargetDispatchEvent(et, event);
}

test "DocumentHTML is a libdom event target" {
    doc = try parser.documentHTMLParseFromStr("<body></body>");
    parser.documentHTMLClose(doc) catch {};

    const event = try parser.eventCreate();
    try parser.eventInit(event, "foo", .{});

    const et = parser.toEventTarget(parser.DocumentHTML, doc);
    _ = try parser.eventTargetDispatchEvent(et, event);
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

const std = @import("std");

const jsruntime = @import("jsruntime");

const parser = @import("netsurf.zig");
const DOM = @import("dom.zig");

const html_test = @import("html_test.zig").html;

var doc: *parser.DocumentHTML = undefined;

fn execJS(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {

    // start JS env
    try js_env.start(alloc, apis);
    defer js_env.stop();

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    // add document object
    try js_env.addObject(apis, doc, "document");

    // launch shellExec
    try jsruntime.shellExec(alloc, js_env, apis);
}

pub fn main() !void {

    // generate APIs
    const apis = comptime jsruntime.compile(DOM.Interfaces);

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    // document
    doc = try parser.documentHTMLParseFromFileAlloc(arena.allocator(), "test.html");
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // launch shell
    try jsruntime.shell(&arena, apis, execJS, .{ .app_name = "browsercore" });
}

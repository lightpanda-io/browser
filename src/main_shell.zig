const std = @import("std");

const jsruntime = @import("jsruntime");
const Console = @import("jsruntime").Console;

const DOM = @import("dom.zig");

const html = @import("html.zig").html;

var doc: DOM.HTMLDocument = undefined;

fn execJS(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {

    // start JS env
    js_env.start();
    defer js_env.stop();

    // add document object
    try js_env.addObject(apis, doc, "document");

    // launch shellExec
    try jsruntime.shellExec(alloc, js_env, apis);
}

pub fn main() !void {

    // generate APIs
    const apis = jsruntime.compile(DOM.Interfaces);

    // document
    doc = DOM.HTMLDocument.init();
    defer doc.deinit();
    try doc.parse(html);

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // alloc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    // launch shell
    try jsruntime.shell(&arena, apis, execJS, .{ .app_name = "browsercore" });
}

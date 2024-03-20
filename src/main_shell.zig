const std = @import("std");

const jsruntime = @import("jsruntime");
const setCAllocator = @import("calloc.zig").setCAllocator;

const parser = @import("netsurf.zig");
const apiweb = @import("apiweb.zig");

const html_test = @import("html_test.zig").html;

pub const Types = jsruntime.reflect(apiweb.Interfaces);

var doc: *parser.DocumentHTML = undefined;

fn execJS(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    // alias global as self and window
    try js_env.attachObject(try js_env.getGlobal(), "self", null);
    try js_env.attachObject(try js_env.getGlobal(), "window", null);

    // add document object
    try js_env.addObject(doc, "document");

    // launch shellExec
    try jsruntime.shellExec(alloc, js_env);
}

pub fn main() !void {

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var c_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer c_arena.deinit();
    setCAllocator(c_arena.allocator());

    // document
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParse(file.reader(), "UTF-8");
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // launch shell
    try jsruntime.shell(&arena, execJS, .{ .app_name = "browsercore" });
}

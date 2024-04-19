const std = @import("std");

const jsruntime = @import("jsruntime");

const parser = @import("netsurf.zig");
const apiweb = @import("apiweb.zig");
const Window = @import("html/window.zig").Window;

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
    var window = Window.create(null);
    window.replaceDocument(doc);
    try js_env.bindGlobal(window);

    // launch shellExec
    try jsruntime.shellExec(alloc, js_env);
}

pub fn main() !void {

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    try parser.init();
    defer parser.deinit();

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

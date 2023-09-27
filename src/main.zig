const std = @import("std");

const jsruntime = @import("jsruntime");

const parser = @import("netsurf.zig");
const DOM = @import("dom.zig");
const docTestExecFn = @import("html/document.zig").testExecFn;
const nodeTestExecFn = @import("dom/node.zig").testExecFn;

const socket_path = "/tmp/browsercore-server.sock";

var doc: *parser.DocumentHTML = undefined;
var server: std.net.StreamServer = undefined;

fn execJS(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    // add document object
    try js_env.addObject(apis, doc, "document");

    while (true) {

        // read cmd
        const conn = try server.accept();
        var buf: [100]u8 = undefined;
        const read = try conn.stream.read(&buf);
        const cmd = buf[0..read];
        std.debug.print("<- {s}\n", .{cmd});
        if (std.mem.eql(u8, cmd, "exit")) {
            break;
        }

        const res = try js_env.execTryCatch(alloc, cmd, "cdp");
        if (res.success) {
            std.debug.print("-> {s}\n", .{res.result});
        }
        _ = try conn.stream.write(res.result);
    }
}

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

pub fn main() !void {

    // generate APIs
    const apis = jsruntime.compile(DOM.Interfaces);

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // document
    var f = "test.html".*;
    doc = parser.documentHTMLParse(&f);
    // TODO: defer doc?

    // // remove socket file of internal server
    // // reuse_address (SO_REUSEADDR flag) does not seems to work on unix socket
    // // see: https://gavv.net/articles/unix-socket-reuse/
    // // TODO: use a lock file instead
    // std.os.unlink(socket_path) catch |err| {
    //     if (err != error.FileNotFound) {
    //         return err;
    //     }
    // };

    // alloc
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var bench_alloc = jsruntime.bench_allocator(gpa.allocator());
    var arena_alloc = std.heap.ArenaAllocator.init(bench_alloc.allocator());
    defer arena_alloc.deinit();

    // // server
    // var addr = try std.net.Address.initUnix(socket_path);
    // server = std.net.StreamServer.init(.{});
    // defer server.deinit();
    // try server.listen(addr);
    // std.debug.print("Listening on: {s}...\n", .{socket_path});

    // try jsruntime.loadEnv(&arena, execJS, apis);
    try jsruntime.loadEnv(&arena_alloc, testsExecFn, apis);
}

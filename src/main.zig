const std = @import("std");

const jsruntime = @import("jsruntime");

const parser = @import("netsurf.zig");
const DOM = @import("dom.zig");

pub const Types = jsruntime.reflect(DOM.Interfaces);

const socket_path = "/tmp/browsercore-server.sock";

var doc: *parser.DocumentHTML = undefined;
var server: std.net.StreamServer = undefined;

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

pub fn main() !void {

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // alloc
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // document
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParse(file.reader(), "UTF-8");
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

    // remove socket file of internal server
    // reuse_address (SO_REUSEADDR flag) does not seems to work on unix socket
    // see: https://gavv.net/articles/unix-socket-reuse/
    // TODO: use a lock file instead
    std.os.unlink(socket_path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };

    // server
    const addr = try std.net.Address.initUnix(socket_path);
    server = std.net.StreamServer.init(.{});
    defer server.deinit();
    try server.listen(addr);
    std.debug.print("Listening on: {s}...\n", .{socket_path});

    try jsruntime.loadEnv(&arena, execJS);
}

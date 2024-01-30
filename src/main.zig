const std = @import("std");

const jsruntime = @import("jsruntime");

const parser = @import("netsurf.zig");
const apiweb = @import("apiweb.zig");

pub const Types = jsruntime.reflect(apiweb.Interfaces);

var doc: *parser.DocumentHTML = undefined;
var server: std.http.Server = undefined;

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

    // TODO: should we do that for each incoming connection
    // ie. in the infinite loop?
    const opts = std.http.Server.AcceptOptions{ .allocator = alloc };

    var resp: std.http.Server.Response = undefined;
    defer resp.deinit();

    while (true) {

        // connection
        resp = try server.accept(opts);
        defer _ = resp.reset();
        try resp.wait();

        // request cmd
        var buf: [128]u8 = undefined;
        const read = try resp.readAll(&buf);
        const cmd = buf[0..read];
        std.debug.print("<- {s}\n", .{cmd});

        // response prepare
        try resp.headers.append("Content-Type", "text/plain");
        try resp.headers.append("Connection", "Keep-Alive");

        // exit case
        if (std.mem.eql(u8, cmd, "exit")) {
            resp.transfer_encoding = .{ .content_length = 0 };
            try resp.send();
            try resp.finish();
            break;
        }

        // JS exec
        const js_res = try js_env.execTryCatch(alloc, cmd, "cdp");
        if (js_res.success) {
            std.debug.print("-> {s}\n", .{js_res.result});
        }

        // response result
        resp.transfer_encoding = .{ .content_length = js_res.result.len };
        try resp.send();
        _ = try resp.writer().writeAll(js_res.result);
        try resp.finish();
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

    // server
    const addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const opts = std.net.StreamServer.Options{
        .reuse_address = true,
        .reuse_port = true,
    };
    server = std.http.Server.init(arena.allocator(), opts);
    defer server.deinit();
    try server.listen(addr);
    std.debug.print("Listening on: {any}...\n", .{addr});

    try jsruntime.loadEnv(&arena, execJS);
}

// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const jsruntime = @import("jsruntime");

const parser = @import("netsurf");
const apiweb = @import("apiweb.zig");
const Window = @import("html/window.zig").Window;

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const UserContext = apiweb.UserContext;

const socket_path = "/tmp/browsercore-server.sock";

var doc: *parser.DocumentHTML = undefined;
var server: std.net.Server = undefined;

fn execJS(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    // start JS env
    try js_env.start();
    defer js_env.stop();

    // alias global as self and window
    var window = Window.create(null);
    window.replaceDocument(doc);
    try js_env.bindGlobal(window);

    // try catch
    var try_catch: jsruntime.TryCatch = undefined;
    try_catch.init(js_env.*);
    defer try_catch.deinit();

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

        const res = try js_env.exec(cmd, "cdp");
        const res_str = try res.toString(alloc, js_env.*);
        defer alloc.free(res_str);
        std.debug.print("-> {s}\n", .{res_str});

        _ = try conn.stream.write(res_str);
    }
}

pub fn main() !void {

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // alloc
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

    // remove socket file of internal server
    // reuse_address (SO_REUSEADDR flag) does not seems to work on unix socket
    // see: https://gavv.net/articles/unix-socket-reuse/
    // TODO: use a lock file instead
    std.posix.unlink(socket_path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };

    // server
    const addr = try std.net.Address.initUnix(socket_path);
    server = try addr.listen(.{});
    defer server.deinit();
    std.debug.print("Listening on: {s}...\n", .{socket_path});

    try jsruntime.loadEnv(&arena, null, execJS);
}

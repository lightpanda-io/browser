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

const server = @import("server.zig");

const parser = @import("netsurf");
const apiweb = @import("apiweb.zig");

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const UserContext = apiweb.UserContext;

const socket_path = "/tmp/browsercore-server.sock";

pub fn main() !void {

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // alloc
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

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
    var srv = std.net.StreamServer.init(.{
        .reuse_address = true,
        .reuse_port = true,
        .force_nonblocking = true,
    });
    defer srv.deinit();
    try srv.listen(addr);
    std.debug.print("Listening on: {s}...\n", .{socket_path});
    server.socket_fd = srv.sockfd.?;

    try jsruntime.loadEnv(&arena, server.execJS);
}

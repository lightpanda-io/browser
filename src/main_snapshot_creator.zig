// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // usage: snapshot_creator [--v8-flags-unsafe "<flags>"] [outfile]
    // A snapshot only deserializes correctly under the flags it was created
    // with, so a runtime using --v8-flags-unsafe needs a snapshot built with
    // the same value.
    var v8_flags: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next(); // executable name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--v8-flags-unsafe")) {
            v8_flags = args.next() orelse {
                std.debug.print("--v8-flags-unsafe requires a value\n", .{});
                return error.MissingArgument;
            };
        } else {
            out_path = arg;
        }
    }

    var platform = try lp.js.Platform.init(v8_flags);
    defer platform.deinit();

    const snapshot = try lp.js.Snapshot.create();
    defer snapshot.deinit();

    var is_stdout = true;
    var file = std.fs.File.stdout();
    if (out_path) |n| {
        is_stdout = false;
        file = try std.fs.cwd().createFile(n, .{});
    }
    defer if (!is_stdout) {
        file.close();
    };

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try snapshot.write(&writer.interface);
    try writer.end();
}

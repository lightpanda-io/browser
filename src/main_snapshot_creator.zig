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

    var platform = try lp.js.Platform.init();
    defer platform.deinit();

    const snapshot = try lp.js.Snapshot.create();
    defer snapshot.deinit();

    var is_stdout = true;
    var file = std.fs.File.stdout();
    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next(); // executable name
    if (args.next()) |n| {
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

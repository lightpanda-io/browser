// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! Writes the docs-site reference partials (`<outdir>/<name>.mdx`), invoked
//! by `zig build docs`.

const std = @import("std");
const lp = @import("lightpanda");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // executable name
    const out_path = args.next() orelse {
        std.debug.print("usage: lightpanda-docs <outdir>\n", .{});
        return error.MissingArgument;
    };

    try std.Io.Dir.cwd().createDirPath(lp.io, out_path);
    var out_dir = try std.Io.Dir.cwd().openDir(lp.io, out_path, .{});
    defer out_dir.close(lp.io);

    for (lp.docs.partials) |p| {
        const file = try out_dir.createFile(lp.io, p.name, .{});
        defer file.close(lp.io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(lp.io, &buffer);
        try p.write(&writer.interface);
        try writer.end();
    }
}

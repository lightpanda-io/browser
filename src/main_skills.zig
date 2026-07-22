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

//! Generates the LLM skill tree (`<outdir>/<name>/SKILL.md`), invoked by
//! `zig build skills`. The documents are rendered from the same code the
//! runtime uses, so they can't go stale.

const std = @import("std");
const lp = @import("lightpanda");

const Skill = struct {
    name: []const u8,
    write: *const fn (writer: *std.Io.Writer) std.Io.Writer.Error!void,
};

const skills = [_]Skill{
    .{ .name = lp.skill.name, .write = lp.skill.write },
};

pub fn main(init: std.process.Init) !void {
    // usage: skills <outdir>
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // executable name
    const out_path = args.next() orelse {
        std.debug.print("usage: lightpanda-skills <outdir>\n", .{});
        return error.MissingArgument;
    };

    try std.Io.Dir.cwd().createDirPath(lp.io, out_path);
    var out_dir = try std.Io.Dir.cwd().openDir(lp.io, out_path, .{});
    defer out_dir.close(lp.io);

    for (skills) |s| {
        try out_dir.createDirPath(lp.io, s.name);
        var skill_dir = try out_dir.openDir(lp.io, s.name, .{});
        defer skill_dir.close(lp.io);

        const file = try skill_dir.createFile(lp.io, "SKILL.md", .{});
        defer file.close(lp.io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(lp.io, &buffer);
        try s.write(&writer.interface);
        try writer.end();
    }
}

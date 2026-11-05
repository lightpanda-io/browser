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

//! Reading and writing agent script files, shared by the agent's `/save` and
//! `/load` and the MCP `save` and `run` tools.

const std = @import("std");
const lp = @import("lightpanda");

/// Upper bound on script source, whether read from a file or piped in.
pub const max_bytes = 10 * 1024 * 1024;

pub fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(lp.io, path, allocator, .limited(max_bytes));
}

/// Writes `content` with a trailing newline, separated by a newline when
/// appending to a non-empty file.
pub fn write(path: []const u8, content: []const u8, append: bool) !void {
    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{ .truncate = !append });
    defer file.close(lp.io);
    var offset: u64 = 0;
    if (append) {
        offset = try file.length(lp.io);
        if (offset > 0 and content.len > 0) {
            try file.writePositionalAll(lp.io, "\n", offset);
            offset += 1;
        }
    }
    try file.writePositionalAll(lp.io, content, offset);
    offset += content.len;
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writePositionalAll(lp.io, "\n", offset);
}

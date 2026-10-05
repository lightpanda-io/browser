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

const std = @import("std");

const truncateUtf8 = @import("string.zig").truncateUtf8;

/// Caps what reaches `inner`. Past the cap, writes fail with `WriteFailed`
/// and `truncated` is set so the caller can tell the cap from an I/O error.
/// A null cap passes everything through.
const LimitedWriter = @This();

pub const truncation_marker = "\n\n[truncated]\n";

inner: *std.Io.Writer,
remaining: ?usize,
truncated: bool = false,
writer: std.Io.Writer,

pub fn init(inner: *std.Io.Writer, max_bytes: ?u32) LimitedWriter {
    return .{
        .inner = inner,
        .remaining = if (max_bytes) |m| @as(usize, m) else null,
        .writer = .{
            .vtable = &vtable,
            .buffer = &.{},
        },
    };
}

const vtable = std.Io.Writer.VTable{ .drain = drain };

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *LimitedWriter = @alignCast(@fieldParentPtr("writer", w));
    var total: usize = 0;
    for (data[0 .. data.len - 1]) |slice| {
        try self.consume(slice);
        total += slice.len;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        try self.consume(pattern);
        total += pattern.len;
    }
    return total;
}

fn consume(self: *LimitedWriter, bytes: []const u8) std.Io.Writer.Error!void {
    const remaining = self.remaining orelse return self.inner.writeAll(bytes);
    if (bytes.len <= remaining) {
        try self.inner.writeAll(bytes);
        self.remaining = remaining - bytes.len;
        return;
    }
    if (remaining > 0) {
        try self.inner.writeAll(truncateUtf8(bytes, remaining));
        self.remaining = 0;
    }
    self.truncated = true;
    return error.WriteFailed;
}

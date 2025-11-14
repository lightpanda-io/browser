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

// Gets the Parent of child.
// HtmlElement.of(script) -> *HTMLElement
pub fn Struct(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        .@"struct" => T,
        .void => T,
        else => unreachable,
    };
}

// Creates an enum of N enums. Doesn't perserve their underlying integer
pub fn mergeEnums(comptime enums: []const type) type {
    const field_count = blk: {
        var count: usize = 0;
        inline for (enums) |e| {
            count += @typeInfo(e).@"enum".fields.len;
        }
        break :blk count;
    };

    var i: usize = 0;
    var fields: [field_count]std.builtin.Type.EnumField = undefined;
    for (enums) |e| {
        for (@typeInfo(e).@"enum".fields) |f| {
            fields[i] = .{
                .name = f.name,
                .value = i,
            };
            i += 1;
        }
    }

    return @Type(.{ .@"enum" = .{
        .decls = &.{},
        .tag_type = blk: {
            if (field_count <= std.math.maxInt(u8)) break :blk u8;
            if (field_count <= std.math.maxInt(u16)) break :blk u16;
            unreachable;
        },
        .fields = &fields,
        .is_exhaustive = true,
    } });
}

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

// ----
const Type = std.builtin.Type;

// Union
// -----

// Generate a flatten tagged Union from a Tuple
pub fn Union(comptime interfaces: anytype) type {
    // @setEvalBranchQuota(10000);
    const tuple = Tuple(interfaces){};
    const fields = std.meta.fields(@TypeOf(tuple));

    const tag_type = switch (fields.len) {
        0 => unreachable,
        1 => u0,
        2 => u1,
        3...4 => u2,
        5...8 => u3,
        9...16 => u4,
        17...32 => u5,
        33...64 => u6,
        65...128 => u7,
        129...256 => u8,
        else => @compileError("Too many interfaces to generate union"),
    };

    // second iteration to generate tags
    var enum_fields: [fields.len]Type.EnumField = undefined;
    for (fields, 0..) |field, index| {
        const member = @field(tuple, field.name);
        const full_name = @typeName(member);
        const separator = std.mem.lastIndexOfScalar(u8, full_name, '.') orelse unreachable;
        const name = full_name[separator + 1 ..];
        enum_fields[index] = .{
            .name = name ++ "",
            .value = index,
        };
    }

    const enum_info = Type.Enum{
        .tag_type = tag_type,
        .fields = &enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    };
    const enum_T = @Type(.{ .@"enum" = enum_info });

    // third iteration to generate union type
    var union_fields: [fields.len]Type.UnionField = undefined;
    for (fields, enum_fields, 0..) |field, e, index| {
        var FT = @field(tuple, field.name);
        if (@hasDecl(FT, "Self")) {
            FT = *(@field(FT, "Self"));
        } else if (!@hasDecl(FT, "union_make_copy")) {
            FT = *FT;
        }
        union_fields[index] = .{
            .type = FT,
            .name = e.name,
            .alignment = @alignOf(FT),
        };
    }

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = enum_T,
        .fields = &union_fields,
        .decls = &.{},
    } });
}

// Tuple
// -----

// Flattens and depuplicates a list of nested tuples. For example
// input: {A, B, {C, B, D}, {A, E}}
// output {A, B, C, D, E}
pub fn Tuple(comptime args: anytype) type {
    @setEvalBranchQuota(100000);

    const count = countInterfaces(args, 0);
    var interfaces: [count]type = undefined;
    _ = flattenInterfaces(args, &interfaces, 0);

    const unfiltered_count, const filter_set = filterMap(count, interfaces);

    var field_index: usize = 0;
    var fields: [unfiltered_count]Type.StructField = undefined;

    for (filter_set, 0..) |filter, i| {
        if (filter) {
            continue;
        }
        fields[field_index] = .{
            .name = std.fmt.comptimePrint("{d}", .{field_index}),
            .type = type,
            // has to be true in order to properly capture the default value
            .is_comptime = true,
            .alignment = @alignOf(type),
            .default_value_ptr = @ptrCast(&interfaces[i]),
        };
        field_index += 1;
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

fn countInterfaces(args: anytype, count: usize) usize {
    var new_count = count;
    for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
        const member = @field(args, f.name);
        if (@TypeOf(member) == type) {
            new_count += 1;
        } else {
            new_count = countInterfaces(member, new_count);
        }
    }
    return new_count;
}

fn flattenInterfaces(args: anytype, interfaces: []type, index: usize) usize {
    var new_index = index;
    for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
        const member = @field(args, f.name);
        if (@TypeOf(member) == type) {
            interfaces[new_index] = member;
            new_index += 1;
        } else {
            new_index = flattenInterfaces(member, interfaces, new_index);
        }
    }
    return new_index;
}

fn filterMap(comptime count: usize, interfaces: [count]type) struct { usize, [count]bool } {
    var map: [count]bool = undefined;
    var unfiltered_count: usize = 0;
    outer: for (interfaces, 0..) |iface, i| {
        for (interfaces[i + 1 ..]) |check| {
            if (iface == check) {
                map[i] = true;
                continue :outer;
            }
        }
        map[i] = false;
        unfiltered_count += 1;
    }
    return .{ unfiltered_count, map };
}

test "generate: Union" {
    const Astruct = struct {
        pub const Self = Other;
        const Other = struct {};
    };

    const Bstruct = struct {
        value: u8 = 0,
    };

    const Cstruct = struct {
        value: u8 = 0,
    };

    const value = Union(.{ Astruct, Bstruct, .{Cstruct} });
    const ti = @typeInfo(value).@"union";
    try std.testing.expectEqual(3, ti.fields.len);
    try std.testing.expectEqualStrings("*browser.js.generate.test.generate: Union.Astruct.Other", @typeName(ti.fields[0].type));
    try std.testing.expectEqualStrings(ti.fields[0].name, "Astruct");
    try std.testing.expectEqual(*Bstruct, ti.fields[1].type);
    try std.testing.expectEqualStrings(ti.fields[1].name, "Bstruct");
    try std.testing.expectEqual(*Cstruct, ti.fields[2].type);
    try std.testing.expectEqualStrings(ti.fields[2].name, "Cstruct");
}

test "generate: Tuple" {
    const Astruct = struct {};

    const Bstruct = struct {
        value: u8 = 0,
    };

    const Cstruct = struct {
        value: u8 = 0,
    };

    {
        const tuple = Tuple(.{ Astruct, Bstruct }){};
        const ti = @typeInfo(@TypeOf(tuple)).@"struct";
        try std.testing.expectEqual(true, ti.is_tuple);
        try std.testing.expectEqual(2, ti.fields.len);
        try std.testing.expectEqual(Astruct, tuple.@"0");
        try std.testing.expectEqual(Bstruct, tuple.@"1");
    }

    {
        // dedupe
        const tuple = Tuple(.{ Cstruct, Astruct, .{Astruct}, Bstruct, .{ Astruct, .{ Astruct, Bstruct } } }){};
        const ti = @typeInfo(@TypeOf(tuple)).@"struct";
        try std.testing.expectEqual(true, ti.is_tuple);
        try std.testing.expectEqual(3, ti.fields.len);
        try std.testing.expectEqual(Cstruct, tuple.@"0");
        try std.testing.expectEqual(Astruct, tuple.@"1");
        try std.testing.expectEqual(Bstruct, tuple.@"2");
    }
}

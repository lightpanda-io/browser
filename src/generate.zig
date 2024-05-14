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
const builtin = @import("builtin");

// Utils
// -----

fn itoa(comptime i: u8) ![]const u8 {
    var len: usize = undefined;
    if (i < 10) {
        len = 1;
    } else if (i < 100) {
        len = 2;
    } else {
        return error.GenerateTooMuchMembers;
    }
    var buf: [len]u8 = undefined;
    return try std.fmt.bufPrint(buf[0..], "{d}", .{i});
}

fn fmtName(comptime T: type) []const u8 {
    var it = std.mem.splitBackwards(u8, @typeName(T), ".");
    return it.first();
}

// Union
// -----

// Generate a flatten tagged Union from various structs and union of structs
// TODO: make this function more generic
// TODO: dedup
pub const Union = struct {
    _enum: type,
    _union: type,

    pub fn compile(comptime tuple: anytype) Union {
        return private_compile(tuple) catch |err| @compileError(@errorName(err));
    }

    fn private_compile(comptime tuple: anytype) !Union {
        @setEvalBranchQuota(10000);

        // check types provided
        const tuple_T = @TypeOf(tuple);
        const tuple_info = @typeInfo(tuple_T);
        if (tuple_info != .Struct or !tuple_info.Struct.is_tuple) {
            return error.GenerateArgNotTuple;
        }

        const tuple_members = tuple_info.Struct.fields;

        // first iteration to get the total number of members
        var members_nb = 0;
        for (tuple_members) |member| {
            const member_T = @field(tuple, member.name);
            const member_info = @typeInfo(member_T);
            if (member_info == .Union) {
                const member_union = member_info.Union;
                members_nb += member_union.fields.len;
            } else if (member_info == .Struct) {
                members_nb += 1;
            } else {
                return error.GenerateMemberNotUnionOrStruct;
            }
        }

        // define the tag type regarding the members nb
        var tag_type: type = undefined;
        if (members_nb < 3) {
            tag_type = u1;
        } else if (members_nb < 4) {
            tag_type = u2;
        } else if (members_nb < 8) {
            tag_type = u3;
        } else if (members_nb < 16) {
            tag_type = u4;
        } else if (members_nb < 32) {
            tag_type = u5;
        } else if (members_nb < 64) {
            tag_type = u6;
        } else if (members_nb < 128) {
            tag_type = u7;
        } else if (members_nb < 256) {
            tag_type = u8;
        } else if (members_nb < 65536) {
            tag_type = u16;
        } else {
            return error.GenerateTooMuchMembers;
        }

        // second iteration to generate tags
        var enum_fields: [members_nb]std.builtin.Type.EnumField = undefined;
        var done = 0;
        for (tuple_members) |member| {
            const member_T = @field(tuple, member.name);
            const member_info = @typeInfo(member_T);
            if (member_info == .Union) {
                const member_union = member_info.Union;
                for (member_union.fields) |field| {
                    enum_fields[done] = .{
                        .name = fmtName(field.type),
                        .value = done,
                    };
                    done += 1;
                }
            } else if (member_info == .Struct) {
                enum_fields[done] = .{
                    .name = fmtName(member_T),
                    .value = done,
                };
                done += 1;
            }
        }
        const decls: [0]std.builtin.Type.Declaration = undefined;
        const enum_info = std.builtin.Type.Enum{
            .tag_type = tag_type,
            .fields = &enum_fields,
            .decls = &decls,
            .is_exhaustive = true,
        };
        const enum_T = @Type(std.builtin.Type{ .Enum = enum_info });

        // third iteration to generate union type
        var union_fields: [members_nb]std.builtin.Type.UnionField = undefined;
        done = 0;
        for (tuple_members, 0..) |member, i| {
            const member_T = @field(tuple, member.name);
            const member_info = @typeInfo(member_T);
            if (member_info == .Union) {
                const member_union = member_info.Union;
                for (member_union.fields) |field| {
                    var T: type = undefined;
                    if (@hasDecl(field.type, "Self")) {
                        T = @field(field.type, "Self");
                        T = *T;
                    } else {
                        T = field.type;
                    }
                    union_fields[done] = .{
                        .name = fmtName(field.type),
                        .type = T,
                        .alignment = @alignOf(T),
                    };
                    done += 1;
                }
            } else if (member_info == .Struct) {
                const member_name = try itoa(i);
                var T = @field(tuple, member_name);
                if (@hasDecl(T, "Self")) {
                    T = @field(T, "Self");
                    T = *T;
                }
                union_fields[done] = .{
                    .name = fmtName(member_T),
                    .type = T,
                    .alignment = @alignOf(T),
                };
                done += 1;
            }
        }
        const union_info = std.builtin.Type.Union{
            .layout = .Auto,
            .tag_type = enum_T,
            .fields = &union_fields,
            .decls = &decls,
        };
        const union_T = @Type(std.builtin.Type{ .Union = union_info });

        return .{
            ._enum = enum_T,
            ._union = union_T,
        };
    }
};

// Tuple
// -----

fn tupleNb(comptime tuple: anytype) usize {
    var nb = 0;
    for (@typeInfo(@TypeOf(tuple)).Struct.fields) |member| {
        const member_T = @field(tuple, member.name);
        if (@TypeOf(member_T) == type) {
            nb += 1;
        } else {
            const member_info = @typeInfo(@TypeOf(member_T));
            if (member_info != .Struct and !member_info.Struct.is_tuple) {
                @compileError("GenerateMemberNotTypeOrTuple");
            }
            for (member_info.Struct.fields) |field| {
                if (@TypeOf(@field(member_T, field.name)) != type) {
                    @compileError("GenerateMemberTupleChildNotType");
                }
            }
            nb += member_info.Struct.fields.len;
        }
    }
    return nb;
}

fn tupleTypes(comptime nb: usize, comptime tuple: anytype) [nb]type {
    var types: [nb]type = undefined;
    var done = 0;
    for (@typeInfo(@TypeOf(tuple)).Struct.fields) |member| {
        const T = @field(tuple, member.name);
        if (@TypeOf(T) == type) {
            types[done] = T;
            done += 1;
        } else {
            const info = @typeInfo(@TypeOf(T));
            for (info.Struct.fields) |field| {
                types[done] = @field(T, field.name);
                done += 1;
            }
        }
    }
    return types;
}

fn isDup(comptime nb: usize, comptime list: [nb]type, comptime T: type, comptime i: usize) bool {
    for (list, 0..) |item, index| {
        if (i >= index) {
            // check sequentially
            continue;
        }
        if (T == item) {
            return true;
        }
    }
    return false;
}

fn dedupIndexes(comptime nb: usize, comptime types: [nb]type) [nb]i32 {
    var dedup_indexes: [nb]i32 = undefined;
    for (types, 0..) |T, i| {
        if (isDup(nb, types, T, i)) {
            dedup_indexes[i] = -1;
        } else {
            dedup_indexes[i] = i;
        }
    }
    return dedup_indexes;
}

fn dedupNb(comptime nb: usize, comptime dedup_indexes: [nb]i32) usize {
    var dedup_nb = 0;
    for (dedup_indexes) |index| {
        if (index != -1) {
            dedup_nb += 1;
        }
    }
    return dedup_nb;
}

fn TupleT(comptime tuple: anytype) type {
    @setEvalBranchQuota(100000);

    // logic
    const nb = tupleNb(tuple);
    const types = tupleTypes(nb, tuple);
    const dedup_indexes = dedupIndexes(nb, types);
    const dedup_nb = dedupNb(nb, dedup_indexes);

    // generate the tuple type
    var fields: [dedup_nb]std.builtin.Type.StructField = undefined;
    var done = 0;
    for (dedup_indexes) |index| {
        if (index == -1) {
            continue;
        }
        fields[done] = .{
            .name = try itoa(done),
            .type = type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(type),
        };
        done += 1;
    }
    const decls: [0]std.builtin.Type.Declaration = undefined;
    const info = std.builtin.Type.Struct{
        .layout = .Auto,
        .fields = &fields,
        .decls = &decls,
        .is_tuple = true,
    };
    return @Type(std.builtin.Type{ .Struct = info });
}

// Create a flatten tuple from various structs and tuple of structs
// Duplicates will be removed.
// TODO: make this function more generic
pub fn Tuple(comptime tuple: anytype) TupleT(tuple) {

    // check types provided
    const tuple_T = @TypeOf(tuple);
    const tuple_info = @typeInfo(tuple_T);
    if (tuple_info != .Struct or !tuple_info.Struct.is_tuple) {
        @compileError("GenerateArgNotTuple");
    }

    // generate the type
    const T = TupleT(tuple);

    // logic
    const nb = tupleNb(tuple);
    const types = tupleTypes(nb, tuple);
    const dedup_indexes = dedupIndexes(nb, types);

    // instantiate the tuple
    var t: T = undefined;
    var done = 0;
    for (dedup_indexes) |index| {
        if (index == -1) {
            continue;
        }
        const name = try itoa(done);
        @field(t, name) = types[index];
        done += 1;
    }
    return t;
}

// Tests
// -----

const Error = error{
    GenerateArgNotTuple,
    GenerateMemberNotUnionOrStruct,
    GenerateMemberNotTupleOrStruct,
    GenerateMemberTupleNotStruct,
    GenerateTooMuchMembers,
};

const Astruct = struct {
    value: u8 = 0,
};
const Bstruct = struct {
    value: u8 = 0,
};
const Cstruct = struct {
    value: u8 = 0,
};
const Dstruct = struct {
    value: u8 = 0,
};

pub fn tests() !void {

    // Union from structs
    const FromStructs = try Union.private_compile(.{ Astruct, Bstruct, Cstruct });

    const from_structs_enum = @typeInfo(FromStructs._enum);
    try std.testing.expect(from_structs_enum == .Enum);
    try std.testing.expect(from_structs_enum.Enum.fields.len == 3);
    try std.testing.expect(from_structs_enum.Enum.tag_type == u2);
    try std.testing.expect(from_structs_enum.Enum.fields[0].value == 0);
    try std.testing.expectEqualStrings(from_structs_enum.Enum.fields[0].name, "Astruct");

    const from_structs_union = @typeInfo(FromStructs._union);
    try std.testing.expect(from_structs_union == .Union);
    try std.testing.expect(from_structs_union.Union.tag_type == FromStructs._enum);
    try std.testing.expect(from_structs_union.Union.fields.len == 3);
    try std.testing.expect(from_structs_union.Union.fields[0].type == Astruct);
    try std.testing.expectEqualStrings(from_structs_union.Union.fields[0].name, "Astruct");

    // Union from union and structs
    const FromMix = try Union.private_compile(.{ FromStructs._union, Dstruct });

    const from_mix_enum = @typeInfo(FromMix._enum);
    try std.testing.expect(from_mix_enum == .Enum);
    try std.testing.expect(from_mix_enum.Enum.fields.len == 4);
    try std.testing.expect(from_mix_enum.Enum.tag_type == u3);
    try std.testing.expect(from_mix_enum.Enum.fields[0].value == 0);
    try std.testing.expectEqualStrings(from_mix_enum.Enum.fields[3].name, "Dstruct");

    const from_mix_union = @typeInfo(FromMix._union);
    try std.testing.expect(from_mix_union == .Union);
    try std.testing.expect(from_mix_union.Union.tag_type == FromMix._enum);
    try std.testing.expect(from_mix_union.Union.fields.len == 4);
    try std.testing.expect(from_mix_union.Union.fields[3].type == Dstruct);
    try std.testing.expectEqualStrings(from_mix_union.Union.fields[3].name, "Dstruct");

    std.debug.print("Generate Union: OK\n", .{});

    // Tuple from structs
    const tuple_structs = .{ Astruct, Bstruct };
    const tFromStructs = Tuple(tuple_structs);
    const t_from_structs = @typeInfo(@TypeOf(tFromStructs));
    try std.testing.expect(t_from_structs == .Struct);
    try std.testing.expect(t_from_structs.Struct.is_tuple);
    try std.testing.expect(t_from_structs.Struct.fields.len == 2);
    try std.testing.expect(@field(tFromStructs, "0") == Astruct);
    try std.testing.expect(@field(tFromStructs, "1") == Bstruct);

    // Tuple from tuple and structs
    const tuple_mix = .{ tFromStructs, Cstruct };
    const tFromMix = Tuple(tuple_mix);
    const t_from_mix = @typeInfo(@TypeOf(tFromMix));
    try std.testing.expect(t_from_mix == .Struct);
    try std.testing.expect(t_from_mix.Struct.is_tuple);
    try std.testing.expect(t_from_mix.Struct.fields.len == 3);
    try std.testing.expect(@field(tFromMix, "0") == Astruct);
    try std.testing.expect(@field(tFromMix, "1") == Bstruct);
    try std.testing.expect(@field(tFromMix, "2") == Cstruct);

    // Tuple with dedup
    const tuple_dedup = .{ Cstruct, Astruct, tFromStructs, Bstruct };
    const tFromDedup = Tuple(tuple_dedup);
    const t_from_dedup = @typeInfo(@TypeOf(tFromDedup));
    try std.testing.expect(t_from_dedup == .Struct);
    try std.testing.expect(t_from_dedup.Struct.is_tuple);
    try std.testing.expect(t_from_dedup.Struct.fields.len == 3);
    try std.testing.expect(@field(tFromDedup, "0") == Cstruct);
    try std.testing.expect(@field(tFromDedup, "1") == Astruct);
    try std.testing.expect(@field(tFromDedup, "2") == Bstruct);

    std.debug.print("Generate Tuple: OK\n", .{});
}

const std = @import("std");
const builtin = @import("builtin");

fn fmtName(comptime T: type) []const u8 {
    var it = std.mem.splitBackwards(u8, @typeName(T), ".");
    return it.first();
}

pub const Union = struct {
    _enum: type,
    _union: type,

    pub fn compile(comptime tuple: anytype) Union {
        comptime {
            return private_compile(tuple) catch @compileError("CompileUnion error");
        }
    }

    fn private_compile(comptime tuple: anytype) !Union {
        @setEvalBranchQuota(10000);

        // check types provided
        const tuple_T = @TypeOf(tuple);
        const tuple_info = @typeInfo(tuple_T);
        if (tuple_info != .Struct or !tuple_info.Struct.is_tuple) {
            return error.GenerateUnionArgNotTuple;
        }

        const tuple_members = tuple_info.Struct.fields;

        // first iteration to get the total number of members
        comptime var members_nb = 0;
        inline for (tuple_members) |member| {
            const member_T = @field(tuple, member.name);
            const member_info = @typeInfo(member_T);
            if (member_info == .Union) {
                const member_union = member_info.Union;
                members_nb += member_union.fields.len;
            } else if (member_info == .Struct) {
                members_nb += 1;
            } else {
                return error.GenerateUnionMemberNotUnionOrStruct;
            }
        }

        // define the tag type regarding the members nb
        comptime var tag_type: type = undefined;
        if (members_nb < 3) {
            tag_type = u1;
        } else if (members_nb < 4) {
            tag_type = u2;
        } else if (members_nb < 8) {
            tag_type = u3;
        } else if (members_nb < 16) {
            tag_type = u4;
        } else if (members_nb < 32) {
            tag_type = u4;
        } else if (members_nb < 64) {
            tag_type = u6;
        } else if (members_nb < 128) {
            tag_type = u7;
        } else if (members_nb < 256) {
            tag_type = u8;
        } else if (members_nb < 65536) {
            tag_type = u16;
        } else {
            return error.GenerateUnionTooMuchMembers;
        }

        // second iteration to generate tags
        comptime var enum_fields: [members_nb]std.builtin.Type.EnumField = undefined;
        comptime var done = 0;
        inline for (tuple_members) |member| {
            const member_T = @field(tuple, member.name);
            const member_info = @typeInfo(member_T);
            if (member_info == .Union) {
                const member_union = member_info.Union;
                inline for (member_union.fields) |field| {
                    enum_fields[done] = .{
                        .name = fmtName(field.field_type),
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
            .layout = .Auto,
            .tag_type = tag_type,
            .fields = &enum_fields,
            .decls = &decls,
            .is_exhaustive = true,
        };
        const enum_T = @Type(std.builtin.Type{ .Enum = enum_info });

        // third iteration to generate union
        comptime var union_fields: [members_nb]std.builtin.Type.UnionField = undefined;
        done = 0;
        inline for (tuple_members) |member, i| {
            const member_T = @field(tuple, member.name);
            const member_info = @typeInfo(member_T);
            if (member_info == .Union) {
                const member_union = member_info.Union;
                inline for (member_union.fields) |field| {
                    union_fields[done] = .{
                        .name = fmtName(field.field_type),
                        .field_type = field.field_type,
                        .alignment = field.alignment,
                    };
                    done += 1;
                }
            } else if (member_info == .Struct) {
                const alignment = tuple_info.Struct.fields[i].alignment;
                union_fields[done] = .{
                    .name = fmtName(member_T),
                    .field_type = member_T,
                    .alignment = alignment,
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

// Tests
// -----

const Error = error{
    UnionArgNotTuple,
    UnionMemberNotUnionOrStruct,
    UnionTooMuchMembers,
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
    try std.testing.expect(from_structs_union.Union.fields[0].field_type == Astruct);
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
    try std.testing.expect(from_mix_union.Union.fields[3].field_type == Dstruct);
    try std.testing.expectEqualStrings(from_mix_union.Union.fields[3].name, "Dstruct");

    std.debug.print("Generate Union: OK\n", .{});
}

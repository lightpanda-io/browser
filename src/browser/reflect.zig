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

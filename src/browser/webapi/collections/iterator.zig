const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

pub fn Entry(comptime Inner: type, comptime field: ?[]const u8) type {
    // const InnerStruct = switch (@typeInfo(Inner)) {
    //     .@"struct" => Inner,
    //     .pointer => |ptr| ptr.child,
    //     else => @compileError("invalid iterator type"),
    // };
    const InnerStruct = Inner;
    const R = reflect(InnerStruct, field);

    return struct {
        inner: Inner,

        const Self = @This();

        const Result = struct {
            done: bool,
            value: ?R.ValueType,

            pub const js_as_object = true;
        };

        pub fn init(inner: Inner, page: *Page) !*Self {
            return page._factory.create(Self{ .inner = inner });
        }

        pub fn next(self: *Self, page: *Page) if (R.has_error_return) anyerror!Result else Result {
            const entry = (if (comptime R.has_error_return) try self.inner.next(page) else self.inner.next(page)) orelse {
                return .{ .done = true, .value = null };
            };

            if (comptime field == null) {
                return .{ .done = false, .value = entry };
            }

            return .{
                .done = false,
                .value = @field(entry, field.?),
            };
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_index: u16 = 0;
            };

            pub const next = bridge.function(Self.next, .{});
            pub const symbol_iterator = bridge.iterator(Self, .{});
        };
    };
}

fn reflect(comptime Inner: type, comptime field: ?[]const u8) Reflect {
    const R = @typeInfo(@TypeOf(Inner.next)).@"fn".return_type.?;
    const has_error_return = @typeInfo(R) == .error_union;
    return .{
        .has_error_return = has_error_return,
        .ValueType = ValueType(unwrapOptional(unwrapError(R)), field),
    };
}

const Reflect = struct {
    has_error_return: bool,
    ValueType: type,
};

fn unwrapError(comptime T: type) type {
    if (@typeInfo(T) == .error_union) {
        return @typeInfo(T).error_union.payload;
    }
    return T;
}

fn unwrapOptional(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

fn ValueType(comptime R: type, comptime field_: ?[]const u8) type {
    const field = field_ orelse return R;
    inline for (@typeInfo(R).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, field)) {
            return f.type;
        }
    }
    @compileError("Unknown EntryIterator field " ++ @typeName(R) ++ "." ++ field);
}

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
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

pub fn Entry(comptime Inner: type, comptime field: ?[]const u8) type {
    const R = reflect(Inner, field);

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

        pub fn deinit(self: *Self, shutdown: bool, page: *Page) void {
            if (@hasDecl(Inner, "deinit")) {
                self.inner.deinit(shutdown, page);
            }
        }

        pub fn acquireRef(self: *Self) void {
            if (@hasDecl(Inner, "acquireRef")) {
                self.inner.acquireRef();
            }
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
                pub var class_id: bridge.ClassId = undefined;
                pub const weak = true;
                pub const finalizer = bridge.finalizer(Self.deinit);
            };

            pub const next = bridge.function(Self.next, .{ .null_as_undefined = true });
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

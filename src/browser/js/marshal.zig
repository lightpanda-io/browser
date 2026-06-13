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

// The engine-agnostic helpers used by both backends' Local.zig to marshal
// values between Zig and JS. Everything here is pure comptime reflection or
// plain integer math - there are NO engine (v8/quickjs) calls - so the two
// backends share a single copy instead of maintaining identical twins.
const std = @import("std");

const registry = @import("registry.zig");

// The result of probing whether a js.Value can become a Zig type T, used by
// the union-coercion ladder in jsValueToZig.
pub fn ProbeResult(comptime T: type) type {
    return union(enum) {
        // The js_value maps directly to T
        value: T,

        // The value is a T. This is almost the same as returning value: T,
        // but the caller still has to get T by calling jsValueToZig.
        // We prefer returning .{.ok => {}}, to avoid reducing duplication
        // with jsValueToZig, but in some cases where probing has a cost
        // AND yields the value anyways, we'll use .{.value = T}.
        ok: void,

        // the js_value is compatible with T (i.e. a int -> float),
        compatible: void,

        // the js_value can be coerced to T (this is a lower precedence
        // than compatible)
        coerce: void,

        // the js_value cannot be turned into T
        invalid: void,
    };
}

pub fn jsSignedIntToZig(comptime T: type, comptime min: comptime_int, max: comptime_int, maybe: i32) !T {
    if (maybe >= min and maybe <= max) {
        return @intCast(maybe);
    }
    return error.InvalidArgument;
}

pub fn jsUnsignedIntToZig(comptime T: type, max: comptime_int, maybe: u32) !T {
    if (maybe <= max) {
        return @intCast(maybe);
    }
    return error.InvalidArgument;
}

// Start at the "resolved" type (the most specific) and work our way up the
// prototype chain looking for the type that defines acquireRef
pub fn findFinalizerType(comptime T: type) ?type {
    const S = registry.Struct(T);
    if (@hasDecl(S, "acquireRef")) {
        return S;
    }
    if (@hasField(S, "_proto")) {
        const ProtoPtr = std.meta.fieldInfo(S, ._proto).type;
        const ProtoChild = @typeInfo(ProtoPtr).pointer.child;
        return findFinalizerType(ProtoChild);
    }
    return null;
}

// Generate a function that follows the _proto pointer chain to get to the finalizer type
pub fn finalizerPtrGetter(comptime T: type, comptime FT: type) *const fn (*T) *FT {
    const S = registry.Struct(T);
    if (S == FT) {
        return struct {
            fn get(v: *T) *FT {
                return v;
            }
        }.get;
    }
    if (@hasField(S, "_proto")) {
        const ProtoPtr = std.meta.fieldInfo(S, ._proto).type;
        const ProtoChild = @typeInfo(ProtoPtr).pointer.child;
        const childGetter = comptime finalizerPtrGetter(ProtoChild, FT);
        return struct {
            fn get(v: *T) *FT {
                return childGetter(v._proto);
            }
        }.get;
    }
    @compileError("Cannot find path from " ++ @typeName(T) ++ " to " ++ @typeName(FT));
}

// Reflects the return type of `global.local(...)` (optional-preserving) so
// Local.toLocal can declare its return type from the Global passed in.
pub fn ToLocalReturnType(comptime T: type) type {
    if (@typeInfo(T) == .optional) {
        const GlobalType = @typeInfo(T).optional.child;
        const struct_info = @typeInfo(GlobalType).@"struct";
        inline for (struct_info.decls) |decl| {
            if (std.mem.eql(u8, decl.name, "local")) {
                const Fn = @TypeOf(@field(GlobalType, "local"));
                const fn_info = @typeInfo(Fn).@"fn";
                return ?fn_info.return_type.?;
            }
        }
        @compileError("Type does not have local method");
    } else {
        const struct_info = @typeInfo(T).@"struct";
        inline for (struct_info.decls) |decl| {
            if (std.mem.eql(u8, decl.name, "local")) {
                const Fn = @TypeOf(@field(T, "local"));
                const fn_info = @typeInfo(Fn).@"fn";
                return fn_info.return_type.?;
            }
        }
        @compileError("Type does not have local method");
    }
}

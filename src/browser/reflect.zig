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

//! Reused metaprogramming routines.

const std = @import("std");

const js = @import("js/js.zig");
const Caller = @import("js/Caller.zig");

const Page = @import("Page.zig");
const Frame = @import("Frame.zig");

// The prototype ("parent") type of T, as declared by its `pub const Proto`.
// This decl is the single source of truth for prototype-chain discovery.
pub fn Proto(comptime T: type) ?type {
    if (!@hasDecl(T, "Proto")) {
        return null;
    }

    if (@hasField(T, "_proto")) {
        // If the field also has a _proto field, it must be the same type: a
        // *Parent, or a Parent when T embeds it
        const F = @FieldType(T, "_proto");
        if (F != *T.Proto and F != T.Proto and F != void) {
            @compileError(@typeName(T) ++ ": _proto field and Proto decl disagree");
        }
    }
    return T.Proto;
}

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

/// Takes a type, can be an optional type, and unwraps it.
pub fn UnwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}

/// Returns whether `T` is one of the Lightpanda objects a bound function can
/// take as its last parameter, filled in by the caller instead of JavaScript.
pub fn isGlobal(comptime T: type) bool {
    return switch (T) {
        // zig fmt: off
        *js.Execution, *const js.Execution,
        *Page, *const Page,
        *Frame, *const Frame,
        => true,
        // zig fmt: on
        else => false,
    };
}

/// Returns whether `T` is a pointer, possibly optional, to a type bound to
/// JavaScript, i.e. one that has a `JsApi`.
pub fn isJavaScriptObject(comptime T: type) bool {
    return switch (@typeInfo(UnwrapOptional(T))) {
        .pointer => |info| info.size == .one and @typeInfo(info.child) == .@"struct" and @hasDecl(info.child, "JsApi"),
        else => false,
    };
}

/// Returns whether function type `F` returns a `js.Promise`, possibly wrapped
/// in an error union.
pub fn returnsPromise(comptime F: type) bool {
    const R = @typeInfo(F).@"fn".return_type orelse return false;
    const payload = switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
    return payload == js.Promise;
}

/// Fast-functions-specific metaprogramming routines. Struct is for namespacing.
pub const fast = struct {
    /// `Caller.FastFunction` has a wrapper per JavaScript argument count, up
    /// to this many: none for a getter, the value for a setter.
    pub const max_js_parameters = 1;

    /// Checks whether a parameter is valid, excluding global objects.
    pub fn isValidParameter(Parameter: ?type) bool {
        if (Parameter) |T| {
            return switch (T) {
                // Primitives cannot be nullable, maybe we can support this some
                // other way around.
                bool, i32, u32, i64, u64, f32, f64 => true,
                else => isJavaScriptObject(T),
            };
        }
        return false;
    }

    /// Returns whether this is a valid receiver (self) type.
    /// Beware, it does not check whether its function is static.
    fn isValidReceiver(comptime T: type) bool {
        if (@typeInfo(T) == .optional) {
            return false;
        }
        return isJavaScriptObject(T);
    }

    /// Returns whether the return type of the function is valid.
    fn isValidReturn(comptime T: type) bool {
        // Unwraps from the error union; optionals are not allowed.
        const Unwrap = switch (@typeInfo(T)) {
            .optional => return false,
            .error_union => |info| info.payload,
            else => T,
        };
        return switch (Unwrap) {
            void, bool, i32, u32, i64, u64, f32, f64 => true,
            else => false,
        };
    }

    /// Returns whether a fast variant can honor `opts`. The wrapper itself only
    /// implements `static`; `exposed` is applied where the member is attached,
    /// so it covers both variants. Any other option has to be left at its
    /// default.
    pub fn hasSupportedOptions(comptime opts: Caller.Function.Opts) bool {
        const supported: Caller.Function.Opts = .{
            .static = opts.static,
            .exposed = opts.exposed,
        };
        return std.meta.eql(opts, supported);
    }

    /// Checks whether a fast variant of a function can be created.
    ///
    /// Conditions for a function to be eligible:
    /// * Options other than `static` and `exposed` must be left at their defaults,
    /// * Parameters must be of type bool, i32, u32, i64, u64, f32, f64 or Object,
    /// * Object parameters (excluding the receiver) can be nullable,
    /// * Lightpanda globals are allowed as the last argument (same as regular variant),
    /// * At most `max_js_parameters` parameters come from JavaScript,
    /// * Return value must be of type void, bool, i32, u32, i64, u64, f32, f64 or error unions of said types.
    pub fn isEligible(comptime Fn: type, comptime opts: Caller.Function.Opts) bool {
        if (comptime !hasSupportedOptions(opts)) {
            return false;
        }

        const info = @typeInfo(Fn).@"fn";
        // Let's first check the return type.
        const Return = info.return_type orelse return false;
        if (comptime !isValidReturn(Return)) {
            return false;
        }

        // If the function is non-static, check if the receiver type is given
        // and valid.
        var params = info.param_types;
        if (comptime !opts.static) {
            if (params.len == 0) {
                // Receiver is missing.
                return false;
            }
            const Receiver = params[0] orelse return false;
            if (comptime !isValidReceiver(Receiver)) {
                // Invalid receiver type.
                return false;
            }
            params = params[1..];
        }
        // Check if there's a trailing global.
        if (comptime params.len > 0) {
            const Parameter = params[params.len - 1] orelse return false;
            // Skip last parameter if it's a global.
            if (comptime isGlobal(Parameter)) {
                params = params[0 .. params.len - 1];
            }
        }

        // JavaScript-side arguments.
        if (params.len > max_js_parameters) {
            return false;
        }
        inline for (params) |Parameter| {
            if (comptime isValidParameter(Parameter) == false) {
                return false;
            }
        }

        return true;
    }
};

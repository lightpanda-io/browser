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

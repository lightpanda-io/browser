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

// The prototype ("parent") type of T, as declared by its `pub const Proto`.
// This decl is the single source of truth for prototype-chain discovery.
pub fn Proto(comptime T: type) ?type {
    if (!@hasDecl(T, "Proto")) {
        return null;
    }

    if (@hasField(T, "_proto")) {
        // If the field also has a _proto: *Parent field, it must be the same type
        const F = @FieldType(T, "_proto");
        if (F != *T.Proto and F != void) {
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

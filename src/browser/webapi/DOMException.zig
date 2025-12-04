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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const DOMException = @This();
_code: Code = .none,

pub fn init() DOMException {
    return .{};
}

pub fn fromError(err: anyerror) ?DOMException {
    return switch (err) {
        error.SyntaxError => .{ ._code = .syntax_error },
        error.InvalidCharacterError => .{ ._code = .invalid_character_error },
        error.NotFound => .{ ._code = .not_found },
        error.NotSupported => .{ ._code = .not_supported },
        error.HierarchyError => .{ ._code = .hierarchy_error },
        error.IndexSizeError => .{ ._code = .index_size_error },
        else => null,
    };
}

pub fn getCode(self: *const DOMException) u8 {
    return @intFromEnum(self._code);
}

pub fn getName(self: *const DOMException) []const u8 {
    return switch (self._code) {
        .none => "Error",
        .invalid_character_error => "InvalidCharacterError",
        .index_size_error => "IndexSizeErorr",
        .syntax_error => "SyntaxError",
        .not_found => "NotFoundError",
        .not_supported => "NotSupportedError",
        .hierarchy_error => "HierarchyError",
    };
}

pub fn getMessage(self: *const DOMException) []const u8 {
    return switch (self._code) {
        .none => "",
        .invalid_character_error => "Invalid Character",
        .index_size_error => "IndexSizeError: Index or size is negative or greater than the allowed amount",
        .syntax_error => "Syntax Error",
        .not_supported => "Not Supported",
        .not_found => "Not Found",
        .hierarchy_error => "Hierarchy Error",
    };
}

const Code = enum(u8) {
    none = 0,
    index_size_error = 1,
    hierarchy_error = 3,
    invalid_character_error = 5,
    not_found = 8,
    not_supported = 9,
    syntax_error = 12,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMException);

    pub const Meta = struct {
        pub const name = "DOMException";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMException.init, .{});
    pub const code = bridge.accessor(DOMException.getCode, null, .{});
    pub const name = bridge.accessor(DOMException.getName, null, .{});
    pub const message = bridge.accessor(DOMException.getMessage, null, .{});
    pub const toString = bridge.function(DOMException.getMessage, .{});
};

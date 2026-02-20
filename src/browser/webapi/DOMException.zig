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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const DOMException = @This();

_code: Code = .none,
_custom_name: ?[]const u8 = null,
_custom_message: ?[]const u8 = null,

pub fn init(message: ?[]const u8, name: ?[]const u8) DOMException {
    // If name is provided, try to map it to a legacy code
    const code = if (name) |n| Code.fromName(n) else .none;
    return .{
        ._code = code,
        ._custom_name = name,
        ._custom_message = message,
    };
}

pub fn fromError(err: anyerror) ?DOMException {
    return switch (err) {
        error.SyntaxError => .{ ._code = .syntax_error },
        error.InvalidCharacterError => .{ ._code = .invalid_character_error },
        error.NotFound => .{ ._code = .not_found },
        error.NotSupported => .{ ._code = .not_supported },
        error.HierarchyError => .{ ._code = .hierarchy_error },
        error.IndexSizeError => .{ ._code = .index_size_error },
        error.InvalidStateError => .{ ._code = .invalid_state_error },
        error.WrongDocument => .{ ._code = .wrong_document_error },
        error.NoModificationAllowed => .{ ._code = .no_modification_allowed_error },
        error.InUseAttribute => .{ ._code = .inuse_attribute_error },
        error.InvalidModification => .{ ._code = .invalid_modification_error },
        error.NamespaceError => .{ ._code = .namespace_error },
        error.InvalidAccess => .{ ._code = .invalid_access_error },
        error.SecurityError => .{ ._code = .security_error },
        error.NetworkError => .{ ._code = .network_error },
        error.AbortError => .{ ._code = .abort_error },
        error.URLMismatch => .{ ._code = .url_mismatch_error },
        error.QuotaExceeded => .{ ._code = .quota_exceeded_error },
        error.TimeoutError => .{ ._code = .timeout_error },
        error.InvalidNodeType => .{ ._code = .invalid_node_type_error },
        error.DataClone => .{ ._code = .data_clone_error },
        else => null,
    };
}

pub fn getCode(self: *const DOMException) u8 {
    return @intFromEnum(self._code);
}

pub fn getName(self: *const DOMException) []const u8 {
    if (self._custom_name) |name| {
        return name;
    }

    return switch (self._code) {
        .none => "Error",
        .index_size_error => "IndexSizeError",
        .hierarchy_error => "HierarchyRequestError",
        .wrong_document_error => "WrongDocumentError",
        .invalid_character_error => "InvalidCharacterError",
        .no_modification_allowed_error => "NoModificationAllowedError",
        .not_found => "NotFoundError",
        .not_supported => "NotSupportedError",
        .inuse_attribute_error => "InUseAttributeError",
        .invalid_state_error => "InvalidStateError",
        .syntax_error => "SyntaxError",
        .invalid_modification_error => "InvalidModificationError",
        .namespace_error => "NamespaceError",
        .invalid_access_error => "InvalidAccessError",
        .security_error => "SecurityError",
        .network_error => "NetworkError",
        .abort_error => "AbortError",
        .url_mismatch_error => "URLMismatchError",
        .quota_exceeded_error => "QuotaExceededError",
        .timeout_error => "TimeoutError",
        .invalid_node_type_error => "InvalidNodeTypeError",
        .data_clone_error => "DataCloneError",
    };
}

pub fn getMessage(self: *const DOMException) []const u8 {
    if (self._custom_message) |msg| {
        return msg;
    }
    return switch (self._code) {
        .none => "",
        .invalid_character_error => "Invalid Character",
        .index_size_error => "Index or size is negative or greater than the allowed amount",
        .syntax_error => "Syntax Error",
        .not_supported => "Not Supported",
        .not_found => "Not Found",
        .hierarchy_error => "Hierarchy Error",
        else => @tagName(self._code),
    };
}

pub fn toString(self: *const DOMException, page: *Page) ![]const u8 {
    const msg = blk: {
        if (self._custom_message) |msg| {
            break :blk msg;
        }
        switch (self._code) {
            .none => return "Error",
            else => break :blk self.getMessage(),
        }
    };
    return std.fmt.bufPrint(&page.buf, "{s}: {s}", .{ self.getName(), msg }) catch return msg;
}

const Code = enum(u8) {
    none = 0,
    index_size_error = 1,
    hierarchy_error = 3,
    wrong_document_error = 4,
    invalid_character_error = 5,
    no_modification_allowed_error = 7,
    not_found = 8,
    not_supported = 9,
    inuse_attribute_error = 10,
    invalid_state_error = 11,
    syntax_error = 12,
    invalid_modification_error = 13,
    namespace_error = 14,
    invalid_access_error = 15,
    security_error = 18,
    network_error = 19,
    abort_error = 20,
    url_mismatch_error = 21,
    quota_exceeded_error = 22,
    timeout_error = 23,
    invalid_node_type_error = 24,
    data_clone_error = 25,

    /// Maps a standard error name to its legacy code
    /// Returns .none (code 0) for non-legacy error names
    pub fn fromName(name: []const u8) Code {
        const lookup = std.StaticStringMap(Code).initComptime(.{
            .{ "IndexSizeError", .index_size_error },
            .{ "HierarchyRequestError", .hierarchy_error },
            .{ "WrongDocumentError", .wrong_document_error },
            .{ "InvalidCharacterError", .invalid_character_error },
            .{ "NoModificationAllowedError", .no_modification_allowed_error },
            .{ "NotFoundError", .not_found },
            .{ "NotSupportedError", .not_supported },
            .{ "InUseAttributeError", .inuse_attribute_error },
            .{ "InvalidStateError", .invalid_state_error },
            .{ "SyntaxError", .syntax_error },
            .{ "InvalidModificationError", .invalid_modification_error },
            .{ "NamespaceError", .namespace_error },
            .{ "InvalidAccessError", .invalid_access_error },
            .{ "SecurityError", .security_error },
            .{ "NetworkError", .network_error },
            .{ "AbortError", .abort_error },
            .{ "URLMismatchError", .url_mismatch_error },
            .{ "QuotaExceededError", .quota_exceeded_error },
            .{ "TimeoutError", .timeout_error },
            .{ "InvalidNodeTypeError", .invalid_node_type_error },
            .{ "DataCloneError", .data_clone_error },
        });
        return lookup.get(name) orelse .none;
    }
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
    pub const toString = bridge.function(DOMException.toString, .{});

    // Legacy error code constants (on both prototype and constructor)
    pub const INDEX_SIZE_ERR = bridge.property(1, .{ .template = true });
    pub const DOMSTRING_SIZE_ERR = bridge.property(2, .{ .template = true });
    pub const HIERARCHY_REQUEST_ERR = bridge.property(3, .{ .template = true });
    pub const WRONG_DOCUMENT_ERR = bridge.property(4, .{ .template = true });
    pub const INVALID_CHARACTER_ERR = bridge.property(5, .{ .template = true });
    pub const NO_DATA_ALLOWED_ERR = bridge.property(6, .{ .template = true });
    pub const NO_MODIFICATION_ALLOWED_ERR = bridge.property(7, .{ .template = true });
    pub const NOT_FOUND_ERR = bridge.property(8, .{ .template = true });
    pub const NOT_SUPPORTED_ERR = bridge.property(9, .{ .template = true });
    pub const INUSE_ATTRIBUTE_ERR = bridge.property(10, .{ .template = true });
    pub const INVALID_STATE_ERR = bridge.property(11, .{ .template = true });
    pub const SYNTAX_ERR = bridge.property(12, .{ .template = true });
    pub const INVALID_MODIFICATION_ERR = bridge.property(13, .{ .template = true });
    pub const NAMESPACE_ERR = bridge.property(14, .{ .template = true });
    pub const INVALID_ACCESS_ERR = bridge.property(15, .{ .template = true });
    pub const VALIDATION_ERR = bridge.property(16, .{ .template = true });
    pub const TYPE_MISMATCH_ERR = bridge.property(17, .{ .template = true });
    pub const SECURITY_ERR = bridge.property(18, .{ .template = true });
    pub const NETWORK_ERR = bridge.property(19, .{ .template = true });
    pub const ABORT_ERR = bridge.property(20, .{ .template = true });
    pub const URL_MISMATCH_ERR = bridge.property(21, .{ .template = true });
    pub const QUOTA_EXCEEDED_ERR = bridge.property(22, .{ .template = true });
    pub const TIMEOUT_ERR = bridge.property(23, .{ .template = true });
    pub const INVALID_NODE_TYPE_ERR = bridge.property(24, .{ .template = true });
    pub const DATA_CLONE_ERR = bridge.property(25, .{ .template = true });
};

const testing = @import("../../testing.zig");
test "WebApi: DOMException" {
    try testing.htmlRunner("domexception.html", .{});
}

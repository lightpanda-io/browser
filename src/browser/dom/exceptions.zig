// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const allocPrint = std.fmt.allocPrint;

const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

// https://webidl.spec.whatwg.org/#idl-DOMException
pub const DOMException = struct {
    err: ?parser.DOMError,
    str: []const u8,

    pub const ErrorSet = parser.DOMError;

    // static attributes
    pub const _INDEX_SIZE_ERR = 1;
    pub const _DOMSTRING_SIZE_ERR = 2;
    pub const _HIERARCHY_REQUEST_ERR = 3;
    pub const _WRONG_DOCUMENT_ERR = 4;
    pub const _INVALID_CHARACTER_ERR = 5;
    pub const _NO_DATA_ALLOWED_ERR = 6;
    pub const _NO_MODIFICATION_ALLOWED_ERR = 7;
    pub const _NOT_FOUND_ERR = 8;
    pub const _NOT_SUPPORTED_ERR = 9;
    pub const _INUSE_ATTRIBUTE_ERR = 10;
    pub const _INVALID_STATE_ERR = 11;
    pub const _SYNTAX_ERR = 12;
    pub const _INVALID_MODIFICATION_ERR = 13;
    pub const _NAMESPACE_ERR = 14;
    pub const _INVALID_ACCESS_ERR = 15;
    pub const _VALIDATION_ERR = 16;
    pub const _TYPE_MISMATCH_ERR = 17;
    pub const _SECURITY_ERR = 18;
    pub const _NETWORK_ERR = 19;
    pub const _ABORT_ERR = 20;
    pub const _URL_MISMATCH_ERR = 21;
    pub const _QUOTA_EXCEEDED_ERR = 22;
    pub const _TIMEOUT_ERR = 23;
    pub const _INVALID_NODE_TYPE_ERR = 24;
    pub const _DATA_CLONE_ERR = 25;

    pub fn constructor(message_: ?[]const u8, name_: ?[]const u8, page: *const Page) !DOMException {
        const message = message_ orelse "";
        const err = if (name_) |n| error_from_str(n) else null;
        const fixed_name = name(err);

        if (message.len == 0) return .{ .err = err, .str = fixed_name };

        const str = try allocPrint(page.arena, "{s}: {s}", .{ fixed_name, message });
        return .{ .err = err, .str = str };
    }

    // TODO: deinit
    pub fn init(alloc: std.mem.Allocator, err: anyerror, caller_name: []const u8) !DOMException {
        const dom_error = @as(parser.DOMError, @errorCast(err));
        const error_name = DOMException.name(dom_error);
        const str = switch (dom_error) {
            error.HierarchyRequest => try allocPrint(
                alloc,
                "{s}: Failed to execute '{s}' on 'Node': The new child element contains the parent.",
                .{ error_name, caller_name },
            ),
            // todo add more custom error messages
            else => try allocPrint(
                alloc,
                "{s}: Failed to execute '{s}' : {s}",
                .{ error_name, caller_name, error_name },
            ),
            error.NoError => unreachable,
        };
        return .{ .err = dom_error, .str = str };
    }

    fn error_from_str(name_: []const u8) ?parser.DOMError {
        // @speed: Consider length first, left as is for maintainability, awaiting switch on string support
        if (std.mem.eql(u8, name_, "IndexSizeError")) return error.IndexSize;
        if (std.mem.eql(u8, name_, "StringSizeError")) return error.StringSize;
        if (std.mem.eql(u8, name_, "HierarchyRequestError")) return error.HierarchyRequest;
        if (std.mem.eql(u8, name_, "WrongDocumentError")) return error.WrongDocument;
        if (std.mem.eql(u8, name_, "InvalidCharacterError")) return error.InvalidCharacter;
        if (std.mem.eql(u8, name_, "NoDataAllowedError")) return error.NoDataAllowed;
        if (std.mem.eql(u8, name_, "NoModificationAllowedError")) return error.NoModificationAllowed;
        if (std.mem.eql(u8, name_, "NotFoundError")) return error.NotFound;
        if (std.mem.eql(u8, name_, "NotSupportedError")) return error.NotSupported;
        if (std.mem.eql(u8, name_, "InuseAttributeError")) return error.InuseAttribute;
        if (std.mem.eql(u8, name_, "InvalidStateError")) return error.InvalidState;
        if (std.mem.eql(u8, name_, "SyntaxError")) return error.Syntax;
        if (std.mem.eql(u8, name_, "InvalidModificationError")) return error.InvalidModification;
        if (std.mem.eql(u8, name_, "NamespaceError")) return error.Namespace;
        if (std.mem.eql(u8, name_, "InvalidAccessError")) return error.InvalidAccess;
        if (std.mem.eql(u8, name_, "ValidationError")) return error.Validation;
        if (std.mem.eql(u8, name_, "TypeMismatchError")) return error.TypeMismatch;
        if (std.mem.eql(u8, name_, "SecurityError")) return error.Security;
        if (std.mem.eql(u8, name_, "NetworkError")) return error.Network;
        if (std.mem.eql(u8, name_, "AbortError")) return error.Abort;
        if (std.mem.eql(u8, name_, "URLismatchError")) return error.URLismatch;
        if (std.mem.eql(u8, name_, "QuotaExceededError")) return error.QuotaExceeded;
        if (std.mem.eql(u8, name_, "TimeoutError")) return error.Timeout;
        if (std.mem.eql(u8, name_, "InvalidNodeTypeError")) return error.InvalidNodeType;
        if (std.mem.eql(u8, name_, "DataCloneError")) return error.DataClone;

        // custom netsurf error
        if (std.mem.eql(u8, name_, "UnspecifiedEventTypeError")) return error.UnspecifiedEventType;
        if (std.mem.eql(u8, name_, "DispatchRequestError")) return error.DispatchRequest;
        if (std.mem.eql(u8, name_, "NoMemoryError")) return error.NoMemory;
        if (std.mem.eql(u8, name_, "AttributeWrongTypeError")) return error.AttributeWrongType;
        return null;
    }

    fn name(err_: ?parser.DOMError) []const u8 {
        const err = err_ orelse return "Error";

        return switch (err) {
            error.IndexSize => "IndexSizeError",
            error.StringSize => "StringSizeError", // Legacy: DOMSTRING_SIZE_ERR
            error.HierarchyRequest => "HierarchyRequestError",
            error.WrongDocument => "WrongDocumentError",
            error.InvalidCharacter => "InvalidCharacterError",
            error.NoDataAllowed => "NoDataAllowedError", // Legacy: NO_DATA_ALLOWED_ERR
            error.NoModificationAllowed => "NoModificationAllowedError",
            error.NotFound => "NotFoundError",
            error.NotSupported => "NotSupportedError",
            error.InuseAttribute => "InuseAttributeError",
            error.InvalidState => "InvalidStateError",
            error.Syntax => "SyntaxError",
            error.InvalidModification => "InvalidModificationError",
            error.Namespace => "NamespaceError",
            error.InvalidAccess => "InvalidAccessError",
            error.Validation => "ValidationError", // Legacy: VALIDATION_ERR
            error.TypeMismatch => "TypeMismatchError",
            error.Security => "SecurityError",
            error.Network => "NetworkError",
            error.Abort => "AbortError",
            error.URLismatch => "URLismatchError",
            error.QuotaExceeded => "QuotaExceededError",
            error.Timeout => "TimeoutError",
            error.InvalidNodeType => "InvalidNodeTypeError",
            error.DataClone => "DataCloneError",
            error.NoError => unreachable,

            // custom netsurf error
            error.UnspecifiedEventType => "UnspecifiedEventTypeError",
            error.DispatchRequest => "DispatchRequestError",
            error.NoMemory => "NoMemoryError",
            error.AttributeWrongType => "AttributeWrongTypeError",
        };
    }

    // JS properties and methods

    pub fn get_code(self: *const DOMException) u8 {
        const err = self.err orelse return 0;
        return switch (err) {
            error.IndexSize => 1,
            error.StringSize => 2,
            error.HierarchyRequest => 3,
            error.WrongDocument => 4,
            error.InvalidCharacter => 5,
            error.NoDataAllowed => 6,
            error.NoModificationAllowed => 7,
            error.NotFound => 8,
            error.NotSupported => 9,
            error.InuseAttribute => 10,
            error.InvalidState => 11,
            error.Syntax => 12,
            error.InvalidModification => 13,
            error.Namespace => 14,
            error.InvalidAccess => 15,
            error.Validation => 16,
            error.TypeMismatch => 17,
            error.Security => 18,
            error.Network => 19,
            error.Abort => 20,
            error.URLismatch => 21,
            error.QuotaExceeded => 22,
            error.Timeout => 23,
            error.InvalidNodeType => 24,
            error.DataClone => 25,
            error.NoError => unreachable,

            // custom netsurf error
            error.UnspecifiedEventType => 128,
            error.DispatchRequest => 129,
            error.NoMemory => 130,
            error.AttributeWrongType => 131,
        };
    }

    pub fn get_name(self: *const DOMException) []const u8 {
        return DOMException.name(self.err);
    }

    pub fn get_message(self: *const DOMException) []const u8 {
        const errName = DOMException.name(self.err);
        if (self.str.len <= errName.len + 2) return "";
        return self.str[errName.len + 2 ..]; // ! Requires str is formatted as "{name}: {message}"
    }

    pub fn _toString(self: *const DOMException) []const u8 {
        return self.str;
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.Exceptions" {
    try testing.htmlRunner("dom/exceptions.html");
}

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
        .syntax_error => "SyntaxError",
        .not_found => "NotFoundError",
        .not_supported => "NotSupported",
        .hierarchy_error => "HierarchyError",
    };
}

pub fn getMessage(self: *const DOMException) []const u8 {
    return switch (self._code) {
        .none => "",
        .invalid_character_error => "Invalid Character",
        .syntax_error => "Syntax Error",
        .not_supported => "Not Supported",
        .not_found => "Not Found",
        .hierarchy_error => "Hierarchy Error",
    };
}

const Code = enum(u8) {
    none = 0,
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

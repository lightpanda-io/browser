const std = @import("std");
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const ErrorEvent = @This();

_proto: *Event,
_message: []const u8 = "",
_filename: []const u8 = "",
_line_number: u32 = 0,
_column_number: u32 = 0,
_error: ?js.Object = null,
_arena: Allocator,

pub const InitOptions = struct {
    message: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    lineno: u32 = 0,
    colno: u32 = 0,
    @"error": ?js.Object = null,
    bubbles: bool = false,
    cancelable: bool = false,
};

pub fn init(typ: []const u8, opts_: ?InitOptions, page: *Page) !*ErrorEvent {
    const arena = page.arena;
    const opts = opts_ orelse InitOptions{};

    const event = try page._factory.event(typ, ErrorEvent{
        ._arena = arena,
        ._proto = undefined,
        ._message = if (opts.message) |str| try arena.dupe(u8, str) else "",
        ._filename = if (opts.filename) |str| try arena.dupe(u8, str) else "",
        ._line_number = opts.lineno,
        ._column_number = opts.colno,
        ._error = if (opts.@"error") |err| try err.persist() else null,
    });

    event._proto._bubbles = opts.bubbles;
    event._proto._cancelable = opts.cancelable;

    return event;
}

pub fn asEvent(self: *ErrorEvent) *Event {
    return self._proto;
}

pub fn getMessage(self: *const ErrorEvent) []const u8 {
    return self._message;
}

pub fn getFilename(self: *const ErrorEvent) []const u8 {
    return self._filename;
}

pub fn getLineNumber(self: *const ErrorEvent) u32 {
    return self._line_number;
}

pub fn getColumnNumber(self: *const ErrorEvent) u32 {
    return self._column_number;
}

pub fn getError(self: *const ErrorEvent) ?js.Object {
    return self._error;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ErrorEvent);

    pub const Meta = struct {
        pub const name = "ErrorEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Start API
    pub const constructor = bridge.constructor(ErrorEvent.init, .{});
    pub const message = bridge.accessor(ErrorEvent.getMessage, null, .{});
    pub const filename = bridge.accessor(ErrorEvent.getFilename, null, .{});
    pub const lineno = bridge.accessor(ErrorEvent.getLineNumber, null, .{});
    pub const colno = bridge.accessor(ErrorEvent.getColumnNumber, null, .{});
    pub const @"error" = bridge.accessor(ErrorEvent.getError, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: ErrorEvent" {
    try testing.htmlRunner("event/error.html", .{});
}

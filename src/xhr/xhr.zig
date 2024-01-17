const std = @import("std");

const generate = @import("../generate.zig");
const EventTarget = @import("../dom/event_target.zig").EventTarget;

const DOMError = @import("../netsurf.zig").DOMError;

// XHR interfaces
// https://xhr.spec.whatwg.org/#interface-xmlhttprequest
pub const Interfaces = generate.Tuple(.{
    XMLHttpRequestEventTarget,
    XMLHttpRequestUpload,
});

pub const XMLHttpRequestEventTarget = struct {
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;
};

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;
};

pub const XMLHttpRequest = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    pub fn constructor() XMLHttpRequest {
        return XMLHttpRequest{};
    }

    pub const UNSENT: u16 = 0;
    pub const OPENED: u16 = 1;
    pub const HEADERS_RECEIVED: u16 = 2;
    pub const LOADING: u16 = 3;
    pub const DONE: u16 = 4;

    readyState: u16 = UNSENT,

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return self.readyState;
    }

    pub fn _open(
        self: *XMLHttpRequest,
        method: []const u8,
        url: []const u8,
        asyn: ?bool,
        username: ?[]const u8,
        password: ?[]const u8,
    ) !void {
        _ = self;
        _ = url;
        _ = asyn;
        _ = username;
        _ = password;

        // TODO If this’s relevant global object is a Window object and its
        // associated Document is not fully active, then throw an
        // "InvalidStateError" DOMException.

        try validMethod(method);
    }

    const methods = [_][]const u8{ "DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT" };
    const methods_forbidden = [_][]const u8{ "CONNECT", "TRACE", "TRACK" };

    pub fn validMethod(m: []const u8) DOMError!void {
        for (methods) |method| {
            if (std.ascii.eqlIgnoreCase(method, m)) {
                return;
            }
        }
        // If method is a forbidden method, then throw a "SecurityError" DOMException.
        for (methods_forbidden) |method| {
            if (std.ascii.eqlIgnoreCase(method, m)) {
                return DOMError.Security;
            }
        }

        // If method is not a method, then throw a "SyntaxError" DOMException.
        return DOMError.Syntax;
    }
};

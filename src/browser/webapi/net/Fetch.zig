const std = @import("std");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const Allocator = std.mem.Allocator;

_arena: Allocator,
_promise: js.Promise,
_has_response: bool,

pub const Input = Request.Input;

pub fn init(input: Input, page: *Page) !js.Promise {
    // @ZIGDOM
    _ = input;
    _ = page;
    return undefined;
}

const std = @import("std");

const js = @import("../../js/js.zig");

const URL = @import("../URL.zig");
const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

const Request = @This();

_url: [:0]const u8,
_arena: Allocator,

pub const Input = union(enum) {
    url: [:0]const u8,
    // request: *Request, TODO
};

pub fn init(input: Input, page: *Page) !*Request {
    const arena = page.arena;
    const url = try URL.resolve(arena, page.url, input.url, .{ .always_dupe = true });

    return page._factory.create(Request{
        ._url = url,
        ._arena = arena,
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Request);

    pub const Meta = struct {
        pub const name = "Request";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(Request.init, .{});
};

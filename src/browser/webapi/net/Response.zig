const std = @import("std");
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

const Response = @This();

_status: u16,
_data: []const u8,
_arena: Allocator,

pub fn initFromFetch(arena: Allocator, data: []const u8, page: *Page) !*Response {
    return page._factory.create(Response{
        ._status = 200,
        ._data = data,
        ._arena = arena,
    });
}

pub fn getStatus(self: *const Response) u16 {
    return self._status;
}

pub fn isOK(self: *const Response) bool {
    return self._status >= 200 and self._status <= 299;
}

pub fn getJson(self: *Response, page: *Page) !js.Promise {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        page.call_arena,
        self._data,
        .{},
    ) catch |err| {
        return page.js.rejectPromise(.{@errorName(err)});
    };
    return page.js.resolvePromise(.{value});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Response);

    pub const Meta = struct {
        pub const name = "Response";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const ok = bridge.accessor(Response.isOK, null, .{});
    pub const status = bridge.accessor(Response.getStatus, null, .{});
    pub const json = bridge.function(Response.getJson, .{});
};

const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const AbortSignal = @import("AbortSignal.zig");

const AbortController = @This();

_signal: *AbortSignal,

pub fn init(page: *Page) !*AbortController {
    const signal = try AbortSignal.init(page);
    return page._factory.create(AbortController{
        ._signal = signal,
    });
}

pub fn getSignal(self: *const AbortController) *AbortSignal {
    return self._signal;
}

pub fn abort(self: *AbortController, reason: ?js.Object, page: *Page) !void {
    try self._signal.abort(reason, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbortController);

    pub const Meta = struct {
        pub const name = "AbortController";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AbortController.init, .{});
    pub const signal = bridge.accessor(AbortController.getSignal, null, .{});
    pub const abort = bridge.function(AbortController.abort, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: AbortController" {
    try testing.htmlRunner("event/abort_controller.html", .{});
}

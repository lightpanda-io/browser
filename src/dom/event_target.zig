const std = @import("std");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("../netsurf.zig");

const DOMException = @import("exceptions.zig").DOMException;

pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn _addEventListener(
        self: *parser.EventTarget,
        alloc: std.mem.Allocator,
        eventType: []const u8,
        cbk: Callback,
    ) !void {
        // TODO: when can we free this allocation?
        const cbk_ptr = try alloc.create(Callback);
        cbk_ptr.* = cbk;
        try parser.eventTargetAddEventListener(self, eventType, cbk_ptr);
    }

    pub fn _dispatchEvent(self: *parser.EventTarget, event: *parser.Event) !bool {
        return try parser.eventTargetDispatchEvent(self, event);
    }

    pub fn deinit(_: *parser.EventTarget, _: std.mem.Allocator) void {}
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var basic = [_]Case{
        .{ .src = "let event = new Event('myEvent')", .ex = "undefined" },
        .{ .src = "let content = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "var nb = 0; content.addEventListener('myEvent', function(event) {nb ++;})", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(event)", .ex = "true" },
        .{ .src = "nb", .ex = "2" }, // 2 because the callback is called twice
    };
    try checkCases(js_env, &basic);
}

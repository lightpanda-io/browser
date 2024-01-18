const std = @import("std");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("../netsurf.zig");

const DOMException = @import("exceptions.zig").DOMException;
const Nod = @import("node.zig");

// EventTarget interfaces
pub const Union = Nod.Union;

// EventTarget implementation
pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    pub fn toInterface(et: *parser.EventTarget) !Union {
        // NOTE: for now we state that all EventTarget are Nodes
        // TODO: handle other types (eg. Window)
        return Nod.Node.toInterface(@as(*parser.Node, @ptrCast(et)));
    }

    // JS funcs
    // --------

    pub fn _addEventListener(
        self: *parser.EventTarget,
        alloc: std.mem.Allocator,
        eventType: []const u8,
        cbk: Callback,
        capture: ?bool,
        // TODO: hanle EventListenerOptions
        // see #https://github.com/lightpanda-io/jsruntime-lib/issues/114
    ) !void {
        // TODO: when can we free this allocation?
        const cbk_ptr = try alloc.create(Callback);
        cbk_ptr.* = cbk;
        try parser.eventTargetAddEventListener(self, eventType, cbk_ptr, capture orelse false);
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
        .{ .src = 
        \\var nb = 0;
        \\var evt = undefined;
        \\var phase = undefined;
        \\var cur = undefined;
        \\content.addEventListener('myEvent',
        \\function(event) {
        \\evt = event;
        \\phase = event.eventPhase;
        \\cur = event.currentTarget;
        \\nb ++;
        \\})
        , .ex = "undefined" },
        .{ .src = "content.dispatchEvent(event)", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt instanceof Event", .ex = "true" },
        .{ .src = "evt.type", .ex = "myEvent" },
        .{ .src = "phase", .ex = "2" },
        .{ .src = "cur.localName", .ex = "div" },
    };
    try checkCases(js_env, &basic);
}

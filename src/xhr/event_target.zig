const std = @import("std");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;

const EventTarget = @import("../dom/event_target.zig").EventTarget;

const parser = @import("../netsurf.zig");

const log = std.log.scoped(.xhr);

pub const XMLHttpRequestEventTarget = struct {
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{},

    onloadstart_cbk: ?Callback = null,
    onprogress_cbk: ?Callback = null,
    onabort_cbk: ?Callback = null,
    onload_cbk: ?Callback = null,
    ontimeout_cbk: ?Callback = null,
    onloadend_cbk: ?Callback = null,

    fn register(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, typ: []const u8, cbk: Callback) !void {
        try parser.eventTargetAddEventListener(@as(*parser.EventTarget, @ptrCast(self)), alloc, typ, cbk, false);
    }
    fn unregister(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, typ: []const u8, cbk: Callback) !void {
        const et = @as(*parser.EventTarget, @ptrCast(self));
        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(et, typ, false, cbk.id());
        if (lst == null) {
            return;
        }

        // remove listener
        try parser.eventTargetRemoveEventListener(et, alloc, typ, lst.?, false);
    }

    pub fn get_onloadstart(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onloadstart_cbk;
    }
    pub fn get_onprogress(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onprogress_cbk;
    }
    pub fn get_onabort(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onabort_cbk;
    }
    pub fn get_onload(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onload_cbk;
    }
    pub fn get_ontimeout(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.ontimeout_cbk;
    }
    pub fn get_onloadend(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onloadend_cbk;
    }

    pub fn set_onloadstart(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onloadstart_cbk) |cbk| try self.unregister(alloc, "loadstart", cbk);
        try self.register(alloc, "loadstart", handler);
        self.onloadstart_cbk = handler;
    }
    pub fn set_onprogress(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onprogress_cbk) |cbk| try self.unregister(alloc, "progress", cbk);
        try self.register(alloc, "progress", handler);
        self.onprogress_cbk = handler;
    }
    pub fn set_onabort(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onabort_cbk) |cbk| try self.unregister(alloc, "abort", cbk);
        try self.register(alloc, "abort", handler);
        self.onabort_cbk = handler;
    }
    pub fn set_onload(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onload_cbk) |cbk| try self.unregister(alloc, "load", cbk);
        try self.register(alloc, "load", handler);
        self.onload_cbk = handler;
    }
    pub fn set_ontimeout(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.ontimeout_cbk) |cbk| try self.unregister(alloc, "timeout", cbk);
        try self.register(alloc, "timeout", handler);
        self.ontimeout_cbk = handler;
    }
    pub fn set_onloadend(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onloadend_cbk) |cbk| try self.unregister(alloc, "loadend", cbk);
        try self.register(alloc, "loadend", handler);
        self.onloadend_cbk = handler;
    }

    pub fn deinit(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator) void {
        parser.eventTargetRemoveAllEventListeners(@as(*parser.EventTarget, @ptrCast(self)), alloc) catch |e| {
            log.err("remove all listeners: {any}", .{e});
        };
    }
};

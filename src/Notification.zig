// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("browser/Frame.zig");
const Transfer = @import("browser/HttpClient.zig").Transfer;
const Request = @import("browser/HttpClient.zig").Request;
const Response = @import("browser/HttpClient.zig").Response;
const InterceptContext = @import("network/layer/InterceptionLayer.zig").InterceptContext;

const log = lp.log;
const List = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

// Allows code to register for and emit events.
// Keeps two lists
// 1 - for a given event type, a linked list of all the listeners
// 2 - for a given listener, a list of all it's registration
// The 2nd one is so that a listener can unregister all of it's listeners
// (there's currently no need for a listener to unregister only 1 or more
// specific listener).
//
// Scoping is important. Imagine we created a global singleton registry, and our
// CDP code registers for the "network_bytes_sent" event, because it needs to
// send messages to the client when this happens. Our HTTP client could then
// emit a "network_bytes_sent" message. It would be easy, and it would work.
// That is, it would work until multiple CDP clients connect, and because
// everything's just one big global, events from one CDP session would be sent
// to all CDP clients.
//
// To avoid this, one way or another, we need scoping. We could still have
// a global registry but every "register" and every "emit" has some type of
// "scope". This would have a run-time cost and still require some coordination
// between components to share a common scope.
//
// Instead, the approach that we take is to have a notification instance per
// CDP connection (BrowserContext). Each CDP connection has its own notification
// that is shared across all Sessions (tabs) within that connection. This ensures
// proper isolation between different CDP clients while allowing a single client
// to receive events from all its tabs.
const Notification = @This();
// Every event type (which are hard-coded), has a list of Listeners.
// When the event happens, we dispatch to those listener.
event_listeners: EventListeners,

// list of listeners for a specified receiver
// @intFromPtr(receiver) -> [listener1, listener2, ...]
// Used when `unregisterAll` is called.
listeners: std.AutoHashMapUnmanaged(usize, std.ArrayList(*Listener)),

allocator: Allocator,
mem_pool: std.heap.MemoryPool(Listener),

const EventListeners = struct {
    frame_remove: List = .{},
    frame_created: List = .{},
    frame_navigate: List = .{},
    frame_navigated: List = .{},
    frame_network_idle: List = .{},
    frame_network_almost_idle: List = .{},
    frame_child_frame_created: List = .{},
    frame_dom_content_loaded: List = .{},
    frame_loaded: List = .{},
    http_request_fail: List = .{},
    http_request_start: List = .{},
    http_request_intercept: List = .{},
    http_request_done: List = .{},
    http_request_auth_required: List = .{},
    http_response_data: List = .{},
    http_response_header_done: List = .{},
    javascript_dialog_opening: List = .{},
};

const Events = union(enum) {
    frame_remove: FrameRemove,
    frame_created: *Frame,
    frame_navigate: *const FrameNavigate,
    frame_navigated: *const FrameNavigated,
    frame_network_idle: *const FrameNetworkIdle,
    frame_network_almost_idle: *const FrameNetworkAlmostIdle,
    frame_child_frame_created: *const FrameChildFrameCreated,
    frame_dom_content_loaded: *const FrameDOMContentLoaded,
    frame_loaded: *const FrameLoaded,
    http_request_fail: *const RequestFail,
    http_request_start: *const RequestStart,
    http_request_intercept: *const RequestIntercept,
    http_request_auth_required: *const RequestAuthRequired,
    http_request_done: *const RequestDone,
    http_response_data: *const ResponseData,
    http_response_header_done: *const ResponseHeaderDone,
    javascript_dialog_opening: *const JavascriptDialogOpening,
};
const EventType = std.meta.FieldEnum(Events);

pub const FrameRemove = struct {};

pub const FrameNavigate = struct {
    req_id: u32,
    frame_id: u32,
    loader_id: u32,
    timestamp: u64,
    url: [:0]const u8,
    opts: Frame.NavigateOpts,
};

pub const FrameNavigated = struct {
    req_id: u32,
    frame_id: u32,
    loader_id: u32,
    timestamp: u64,
    url: [:0]const u8,
    opts: Frame.NavigatedOpts,
};

pub const FrameNetworkIdle = struct {
    req_id: u32,
    frame_id: u32,
    loader_id: u32,
    timestamp: u64,
};

pub const FrameNetworkAlmostIdle = struct {
    req_id: u32,
    frame_id: u32,
    loader_id: u32,
    timestamp: u64,
};

pub const FrameChildFrameCreated = struct {
    frame_id: u32,
    loader_id: u32,
    parent_id: u32,
    timestamp: u64,
};

pub const FrameDOMContentLoaded = struct {
    req_id: u32,
    frame_id: u32,
    loader_id: u32,
    timestamp: u64,
};

pub const FrameLoaded = struct {
    req_id: u32,
    frame_id: u32,
    loader_id: u32,
    timestamp: u64,
};

pub const RequestStart = struct {
    request: *Request,
};

pub const RequestIntercept = struct {
    request: *Request,
    wait_for_interception: *bool,
};

pub const RequestAuthRequired = struct {
    transfer: *Transfer,
    wait_for_interception: *bool,
};

pub const ResponseData = struct {
    data: []const u8,
    request: *Request,
};

pub const ResponseHeaderDone = struct {
    request: *Request,
    response: *const Response,
};

pub const RequestDone = struct {
    request: *Request,
    content_length: usize,
};

pub const RequestFail = struct {
    request: *Request,
    err: anyerror,
};

pub const JavascriptDialogOpening = struct {
    url: [:0]const u8,
    message: []const u8,
    dialog_type: []const u8,
    // Output param. The CDP listener may set this from a pre-armed response
    // queued by Page.handleJavaScriptDialog. The dispatcher (alert/confirm/
    // prompt in Window.zig) reads it back to decide what to return to JS.
    // Headless mode auto-dismisses if no listener fills it in: confirm→false,
    // prompt→null, alert→void (default-zero DialogResponse).
    response: *DialogResponse,
};

pub const DialogResponse = struct {
    accept: bool = false,
    // Set when the CDP client sent a `promptText` with `accept: true`. Memory
    // is owned by whoever filled in the response (typically the BrowserContext
    // arena) and must outlive a single dispatch call.
    prompt_text: ?[]const u8 = null,
};

pub fn init(allocator: Allocator) !*Notification {
    const notification = try allocator.create(Notification);
    errdefer allocator.destroy(notification);

    notification.* = .{
        .listeners = .{},
        .event_listeners = .{},
        .allocator = allocator,
        .mem_pool = std.heap.MemoryPool(Listener).init(allocator),
    };

    return notification;
}

pub fn deinit(self: *Notification) void {
    const allocator = self.allocator;

    var it = self.listeners.valueIterator();
    while (it.next()) |listener| {
        listener.deinit(allocator);
    }
    self.listeners.deinit(allocator);
    self.mem_pool.deinit();
    allocator.destroy(self);
}

pub fn register(self: *Notification, comptime event: EventType, receiver: anytype, func: EventFunc(event)) !void {
    var list = &@field(self.event_listeners, @tagName(event));

    var listener = try self.mem_pool.create();
    errdefer self.mem_pool.destroy(listener);

    listener.* = .{
        .node = .{},
        .list = list,
        .receiver = receiver,
        .event = event,
        .func = @ptrCast(func),
        .struct_name = @typeName(@typeInfo(@TypeOf(receiver)).pointer.child),
    };

    const allocator = self.allocator;
    const gop = try self.listeners.getOrPut(allocator, @intFromPtr(receiver));
    if (gop.found_existing == false) {
        gop.value_ptr.* = .{};
    }
    try gop.value_ptr.append(allocator, listener);

    // we don't add this until we've successfully added the entry to
    // self.listeners
    list.append(&listener.node);
}

pub fn unregister(self: *Notification, comptime event: EventType, receiver: anytype) void {
    var listeners = self.listeners.getPtr(@intFromPtr(receiver)) orelse return;

    var i: usize = 0;
    while (i < listeners.items.len) {
        const listener = listeners.items[i];
        if (listener.event != event) {
            i += 1;
            continue;
        }
        listener.list.remove(&listener.node);
        self.mem_pool.destroy(listener);
        _ = listeners.swapRemove(i);
    }

    if (listeners.items.len == 0) {
        listeners.deinit(self.allocator);
        const removed = self.listeners.remove(@intFromPtr(receiver));
        lp.assert(removed == true, "Notification.unregister", .{ .type = event });
    }
}

pub fn unregisterAll(self: *Notification, receiver: *anyopaque) void {
    var kv = self.listeners.fetchRemove(@intFromPtr(receiver)) orelse return;
    for (kv.value.items) |listener| {
        listener.list.remove(&listener.node);
        self.mem_pool.destroy(listener);
    }
    kv.value.deinit(self.allocator);
}

pub fn dispatch(self: *Notification, comptime event: EventType, data: ArgType(event)) void {
    if (self.listeners.count() == 0) {
        return;
    }
    const list = &@field(self.event_listeners, @tagName(event));

    var node = list.first;
    while (node) |n| {
        const listener: *Listener = @fieldParentPtr("node", n);
        const func: EventFunc(event) = @ptrCast(@alignCast(listener.func));
        func(listener.receiver, data) catch |err| {
            log.err(.app, "dispatch error", .{
                .err = err,
                .event = event,
                .source = "notification",
                .listener = listener.struct_name,
            });
        };
        node = n.next;
    }
}

// Given an event type enum, returns the type of arg the event emits
fn ArgType(comptime event: Notification.EventType) type {
    inline for (std.meta.fields(Notification.Events)) |f| {
        if (std.mem.eql(u8, f.name, @tagName(event))) {
            return f.type;
        }
    }
    unreachable;
}

// Given an event type enum, returns the listening function type
fn EventFunc(comptime event: Notification.EventType) type {
    return *const fn (*anyopaque, ArgType(event)) anyerror!void;
}

// A listener. This is 1 receiver, with its function, and the linked list
// node that goes in the appropriate EventListeners list.
const Listener = struct {
    // the receiver of the event, i.e. the self parameter to `func`
    receiver: *anyopaque,

    // the function to call
    func: *const anyopaque,

    // For logging slightly better error
    struct_name: []const u8,

    event: Notification.EventType,

    // intrusive linked list node
    node: List.Node,

    // The event list this listener belongs to.
    // We need this in order to be able to remove the node from the list
    list: *List,
};

const testing = std.testing;
test "Notification" {
    var notifier = try Notification.init(testing.allocator);
    defer notifier.deinit();

    // noop
    notifier.dispatch(.frame_navigate, &.{
        .loader_id = 39,
        .frame_id = 0,
        .req_id = 1,
        .timestamp = 4,
        .url = undefined,
        .opts = .{},
    });

    var tc = TestClient{};

    try notifier.register(.frame_navigate, &tc, TestClient.frameNavigate);
    notifier.dispatch(.frame_navigate, &.{
        .loader_id = 39,
        .frame_id = 0,
        .req_id = 1,
        .timestamp = 4,
        .url = undefined,
        .opts = .{},
    });
    try testing.expectEqual(4, tc.frame_navigate);

    notifier.unregisterAll(&tc);
    notifier.dispatch(.frame_navigate, &.{
        .loader_id = 39,
        .frame_id = 0,
        .req_id = 1,
        .timestamp = 10,
        .url = undefined,
        .opts = .{},
    });
    try testing.expectEqual(4, tc.frame_navigate);

    try notifier.register(.frame_navigate, &tc, TestClient.frameNavigate);
    try notifier.register(.frame_navigated, &tc, TestClient.frameNavigated);
    notifier.dispatch(.frame_navigate, &.{
        .loader_id = 39,
        .frame_id = 0,
        .req_id = 1,
        .timestamp = 10,
        .url = undefined,
        .opts = .{},
    });
    notifier.dispatch(.frame_navigated, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 6, .url = undefined, .opts = .{} });
    try testing.expectEqual(14, tc.frame_navigate);
    try testing.expectEqual(6, tc.frame_navigated);

    notifier.unregisterAll(&tc);
    notifier.dispatch(.frame_navigate, &.{
        .loader_id = 39,
        .frame_id = 0,
        .req_id = 1,
        .timestamp = 100,
        .url = undefined,
        .opts = .{},
    });
    notifier.dispatch(.frame_navigated, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 100, .url = undefined, .opts = .{} });
    try testing.expectEqual(14, tc.frame_navigate);
    try testing.expectEqual(6, tc.frame_navigated);

    {
        // unregister
        try notifier.register(.frame_navigate, &tc, TestClient.frameNavigate);
        try notifier.register(.frame_navigated, &tc, TestClient.frameNavigated);
        notifier.dispatch(.frame_navigate, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.frame_navigated, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 1000, .url = undefined, .opts = .{} });
        try testing.expectEqual(114, tc.frame_navigate);
        try testing.expectEqual(1006, tc.frame_navigated);

        notifier.unregister(.frame_navigate, &tc);
        notifier.dispatch(.frame_navigate, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.frame_navigated, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 1000, .url = undefined, .opts = .{} });
        try testing.expectEqual(114, tc.frame_navigate);
        try testing.expectEqual(2006, tc.frame_navigated);

        notifier.unregister(.frame_navigated, &tc);
        notifier.dispatch(.frame_navigate, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.frame_navigated, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 1000, .url = undefined, .opts = .{} });
        try testing.expectEqual(114, tc.frame_navigate);
        try testing.expectEqual(2006, tc.frame_navigated);

        // already unregistered, try anyways
        notifier.unregister(.frame_navigated, &tc);
        notifier.dispatch(.frame_navigate, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.frame_navigated, &.{ .loader_id = 39, .frame_id = 0, .req_id = 1, .timestamp = 1000, .url = undefined, .opts = .{} });
        try testing.expectEqual(114, tc.frame_navigate);
        try testing.expectEqual(2006, tc.frame_navigated);
    }
}

const TestClient = struct {
    frame_navigate: u64 = 0,
    frame_navigated: u64 = 0,

    fn frameNavigate(ptr: *anyopaque, data: *const Notification.FrameNavigate) !void {
        const self: *TestClient = @ptrCast(@alignCast(ptr));
        self.frame_navigate += data.timestamp;
    }

    fn frameNavigated(ptr: *anyopaque, data: *const Notification.FrameNavigated) !void {
        const self: *TestClient = @ptrCast(@alignCast(ptr));
        self.frame_navigated += data.timestamp;
    }
};

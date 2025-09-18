const std = @import("std");

const log = @import("log.zig");
const page = @import("browser/page.zig");
const Transfer = @import("http/Client.zig").Transfer;

const Allocator = std.mem.Allocator;

const List = std.DoublyLinkedList;

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
// That is, it would work until the Telemetry code makes an HTTP request, and
// because everything's just one big global, that gets picked up by the
// registered CDP listener, and the telemetry network activity gets sent to the
// CDP client.
//
// To avoid this, one way or another, we need scoping. We could still have
// a global registry but every "register" and every "emit" has some type of
// "scope". This would have a run-time cost and still require some coordination
// between components to share a common scope.
//
// Instead, the approach that we take is to have a notification instance per
// scope. This makes some things harder, but we only plan on having 2
// notification instances  at a given time: one in a Browser and one in the App.
// What about something like Telemetry, which lives outside of a Browser but
// still cares about Browser-events (like .page_navigate)? When the Browser
// notification is created, a `notification_created` event is raised in the
// App's notification, which Telemetry is registered for. This allows Telemetry
// to register for events in the Browser notification. See the Telemetry's
// register function.
pub const Notification = struct {
    // Every event type (which are hard-coded), has a list of Listeners.
    // When the event happens, we dispatch to those listener.
    event_listeners: EventListeners,

    // list of listeners for a specified receiver
    // @intFromPtr(receiver) -> [listener1, listener2, ...]
    // Used when `unregisterAll` is called.
    listeners: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(*Listener)),

    allocator: Allocator,
    mem_pool: std.heap.MemoryPool(Listener),

    const EventListeners = struct {
        page_remove: List = .{},
        page_created: List = .{},
        page_navigate: List = .{},
        page_navigated: List = .{},
        page_network_idle: List = .{},
        page_network_almost_idle: List = .{},
        http_request_fail: List = .{},
        http_request_start: List = .{},
        http_request_intercept: List = .{},
        http_request_done: List = .{},
        http_request_auth_required: List = .{},
        http_response_data: List = .{},
        http_response_header_done: List = .{},
        notification_created: List = .{},
    };

    const Events = union(enum) {
        page_remove: PageRemove,
        page_created: *page.Page,
        page_navigate: *const PageNavigate,
        page_navigated: *const PageNavigated,
        page_network_idle: *const PageNetworkIdle,
        page_network_almost_idle: *const PageNetworkAlmostIdle,
        http_request_fail: *const RequestFail,
        http_request_start: *const RequestStart,
        http_request_intercept: *const RequestIntercept,
        http_request_auth_required: *const RequestAuthRequired,
        http_request_done: *const RequestDone,
        http_response_data: *const ResponseData,
        http_response_header_done: *const ResponseHeaderDone,
        notification_created: *Notification,
    };
    const EventType = std.meta.FieldEnum(Events);

    pub const PageRemove = struct {};

    pub const PageNavigate = struct {
        timestamp: u32,
        url: []const u8,
        opts: page.NavigateOpts,
    };

    pub const PageNavigated = struct {
        timestamp: u32,
        url: []const u8,
    };

    pub const PageNetworkIdle = struct {
        timestamp: u32,
    };

    pub const PageNetworkAlmostIdle = struct {
        timestamp: u32,
    };

    pub const RequestStart = struct {
        transfer: *Transfer,
    };

    pub const RequestIntercept = struct {
        transfer: *Transfer,
        wait_for_interception: *bool,
    };

    pub const RequestAuthRequired = struct {
        transfer: *Transfer,
        wait_for_interception: *bool,
    };

    pub const ResponseData = struct {
        data: []const u8,
        transfer: *Transfer,
    };

    pub const ResponseHeaderDone = struct {
        transfer: *Transfer,
    };

    pub const RequestDone = struct {
        transfer: *Transfer,
    };

    pub const RequestFail = struct {
        transfer: *Transfer,
        err: anyerror,
    };

    pub fn init(allocator: Allocator, parent: ?*Notification) !*Notification {
        // This is put on the heap because we want to raise a .notification_created
        // event, so that, something like Telemetry, can receive the
        // .page_navigate event on all notification instances. That can only work
        // if we dispatch .notification_created with a *Notification.
        const notification = try allocator.create(Notification);
        errdefer allocator.destroy(notification);

        notification.* = .{
            .listeners = .{},
            .event_listeners = .{},
            .allocator = allocator,
            .mem_pool = std.heap.MemoryPool(Listener).init(allocator),
        };

        if (parent) |pn| {
            pn.dispatch(.notification_created, notification);
        }

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
            std.debug.assert(removed == true);
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
};

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
    var notifier = try Notification.init(testing.allocator, null);
    defer notifier.deinit();

    // noop
    notifier.dispatch(.page_navigate, &.{
        .timestamp = 4,
        .url = undefined,
        .opts = .{},
    });

    var tc = TestClient{};

    try notifier.register(.page_navigate, &tc, TestClient.pageNavigate);
    notifier.dispatch(.page_navigate, &.{
        .timestamp = 4,
        .url = undefined,
        .opts = .{},
    });
    try testing.expectEqual(4, tc.page_navigate);

    notifier.unregisterAll(&tc);
    notifier.dispatch(.page_navigate, &.{
        .timestamp = 10,
        .url = undefined,
        .opts = .{},
    });
    try testing.expectEqual(4, tc.page_navigate);

    try notifier.register(.page_navigate, &tc, TestClient.pageNavigate);
    try notifier.register(.page_navigated, &tc, TestClient.pageNavigated);
    notifier.dispatch(.page_navigate, &.{
        .timestamp = 10,
        .url = undefined,
        .opts = .{},
    });
    notifier.dispatch(.page_navigated, &.{ .timestamp = 6, .url = undefined });
    try testing.expectEqual(14, tc.page_navigate);
    try testing.expectEqual(6, tc.page_navigated);

    notifier.unregisterAll(&tc);
    notifier.dispatch(.page_navigate, &.{
        .timestamp = 100,
        .url = undefined,
        .opts = .{},
    });
    notifier.dispatch(.page_navigated, &.{ .timestamp = 100, .url = undefined });
    try testing.expectEqual(14, tc.page_navigate);
    try testing.expectEqual(6, tc.page_navigated);

    {
        // unregister
        try notifier.register(.page_navigate, &tc, TestClient.pageNavigate);
        try notifier.register(.page_navigated, &tc, TestClient.pageNavigated);
        notifier.dispatch(.page_navigate, &.{ .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.page_navigated, &.{ .timestamp = 1000, .url = undefined });
        try testing.expectEqual(114, tc.page_navigate);
        try testing.expectEqual(1006, tc.page_navigated);

        notifier.unregister(.page_navigate, &tc);
        notifier.dispatch(.page_navigate, &.{ .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.page_navigated, &.{ .timestamp = 1000, .url = undefined });
        try testing.expectEqual(114, tc.page_navigate);
        try testing.expectEqual(2006, tc.page_navigated);

        notifier.unregister(.page_navigated, &tc);
        notifier.dispatch(.page_navigate, &.{ .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.page_navigated, &.{ .timestamp = 1000, .url = undefined });
        try testing.expectEqual(114, tc.page_navigate);
        try testing.expectEqual(2006, tc.page_navigated);

        // already unregistered, try anyways
        notifier.unregister(.page_navigated, &tc);
        notifier.dispatch(.page_navigate, &.{ .timestamp = 100, .url = undefined, .opts = .{} });
        notifier.dispatch(.page_navigated, &.{ .timestamp = 1000, .url = undefined });
        try testing.expectEqual(114, tc.page_navigate);
        try testing.expectEqual(2006, tc.page_navigated);
    }
}

const TestClient = struct {
    page_navigate: u32 = 0,
    page_navigated: u32 = 0,

    fn pageNavigate(ptr: *anyopaque, data: *const Notification.PageNavigate) !void {
        const self: *TestClient = @ptrCast(@alignCast(ptr));
        self.page_navigate += data.timestamp;
    }

    fn pageNavigated(ptr: *anyopaque, data: *const Notification.PageNavigated) !void {
        const self: *TestClient = @ptrCast(@alignCast(ptr));
        self.page_navigated += data.timestamp;
    }
};

const std = @import("std");
const js = @import("js.zig");
const v8 = js.v8;

const Context = @import("Context.zig");

const Allocator = std.mem.Allocator;

const Inspector = @This();

pub const RemoteObject = v8.RemoteObject;

isolate: v8.Isolate,
inner: *v8.Inspector,
session: v8.InspectorSession,

// We expect allocator to be an arena
pub fn init(allocator: Allocator, isolate: v8.Isolate, ctx: anytype) !Inspector {
    const ContextT = @TypeOf(ctx);

    const InspectorContainer = switch (@typeInfo(ContextT)) {
        .@"struct" => ContextT,
        .pointer => |ptr| ptr.child,
        .void => NoopInspector,
        else => @compileError("invalid context type"),
    };

    // If necessary, turn a void context into something we can safely ptrCast
    const safe_context: *anyopaque = if (ContextT == void) @ptrCast(@constCast(&{})) else ctx;

    const channel = v8.InspectorChannel.init(safe_context, InspectorContainer.onInspectorResponse, InspectorContainer.onInspectorEvent, isolate);

    const client = v8.InspectorClient.init();

    const inner = try allocator.create(v8.Inspector);
    v8.Inspector.init(inner, client, channel, isolate);
    return .{ .inner = inner, .isolate = isolate, .session = inner.connect() };
}

pub fn deinit(self: *const Inspector) void {
    self.session.deinit();
    self.inner.deinit();
}

pub fn send(self: *const Inspector, msg: []const u8) void {
    // Can't assume the main Context exists (with its HandleScope)
    // available when doing this. Pages (and thus the HandleScope)
    // comes and goes, but CDP can keep sending messages.
    const isolate = self.isolate;
    var temp_scope: v8.HandleScope = undefined;
    v8.HandleScope.init(&temp_scope, isolate);
    defer temp_scope.deinit();

    self.session.dispatchProtocolMessage(isolate, msg);
}

// From CDP docs
// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#type-ExecutionContextDescription
// ----
// - name: Human readable name describing given context.
// - origin: Execution context origin (ie. URL who initialised the request)
// - auxData: Embedder-specific auxiliary data likely matching
// {isDefault: boolean, type: 'default'|'isolated'|'worker', frameId: string}
// - is_default_context: Whether the execution context is default, should match the auxData
pub fn contextCreated(
    self: *const Inspector,
    context: *const Context,
    name: []const u8,
    origin: []const u8,
    aux_data: ?[]const u8,
    is_default_context: bool,
) void {
    self.inner.contextCreated(context.v8_context, name, origin, aux_data, is_default_context);
}

// Retrieves the RemoteObject for a given value.
// The value is loaded through the ExecutionWorld's mapZigInstanceToJs function,
// just like a method return value. Therefore, if we've mapped this
// value before, we'll get the existing JS PersistedObject and if not
// we'll create it and track it for cleanup when the context ends.
pub fn getRemoteObject(
    self: *const Inspector,
    context: *Context,
    group: []const u8,
    value: anytype,
) !RemoteObject {
    const js_value = try context.zigValueToJs(value);

    // We do not want to expose this as a parameter for now
    const generate_preview = false;
    return self.session.wrapObject(
        context.isolate,
        context.v8_context,
        js_value,
        group,
        generate_preview,
    );
}

// Gets a value by object ID regardless of which context it is in.
pub fn getNodePtr(self: *const Inspector, allocator: Allocator, object_id: []const u8) !?*anyopaque {
    const unwrapped = try self.session.unwrapObject(allocator, object_id);
    // The values context and groupId are not used here
    const toa = getTaggedAnyOpaque(unwrapped.value) orelse return null;
    if (toa.subtype == null or toa.subtype != .node) return error.ObjectIdIsNotANode;
    return toa.ptr;
}

const NoopInspector = struct {
    pub fn onInspectorResponse(_: *anyopaque, _: u32, _: []const u8) void {}
    pub fn onInspectorEvent(_: *anyopaque, _: []const u8) void {}
};

pub fn getTaggedAnyOpaque(value: v8.Value) ?*js.TaggedAnyOpaque {
    if (value.isObject() == false) {
        return null;
    }
    const obj = value.castTo(v8.Object);
    if (obj.internalFieldCount() == 0) {
        return null;
    }

    const external_data = obj.getInternalField(0).castTo(v8.External).get().?;
    return @ptrCast(@alignCast(external_data));
}

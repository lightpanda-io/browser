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
const js = @import("js.zig");
const v8 = js.v8;

const TaggedOpaque = @import("TaggedOpaque.zig");

const Allocator = std.mem.Allocator;
const RndGen = std.Random.DefaultPrng;

const CONTEXT_GROUP_ID = 1;
const CLIENT_TRUST_LEVEL = 1;

const Inspector = @This();

handle: *v8.Inspector,
isolate: *v8.Isolate,
client: Client,
channel: Channel,
session: Session,
rnd: RndGen = RndGen.init(0),
default_context: ?v8.Global,

// We expect allocator to be an arena
// Note: This initializes the pre-allocated inspector in-place
pub fn init(self: *Inspector, isolate: *v8.Isolate, ctx: anytype) !void {
    const ContextT = @TypeOf(ctx);

    const Container = switch (@typeInfo(ContextT)) {
        .@"struct" => ContextT,
        .pointer => |ptr| ptr.child,
        .void => NoopInspector,
        else => @compileError("invalid context type"),
    };
    // If necessary, turn a void context into something we can safely ptrCast
    const safe_context: *anyopaque = if (ContextT == void) @ptrCast(@constCast(&{})) else ctx;

    // Initialize the fields that callbacks need first
    self.* = .{
        .handle = undefined,
        .isolate = isolate,
        .client = undefined,
        .channel = undefined,
        .rnd = RndGen.init(0),
        .default_context = null,
        .session = undefined,
    };

    // Create client and set inspector data BEFORE creating the inspector
    // because V8 will call generateUniqueId during inspector creation
    const client = Client.init();
    self.client = client;
    client.setInspector(self);

    // Now create the inspector - generateUniqueId will work because data is set
    const handle = v8.v8_inspector__Inspector__Create(isolate, client.handle).?;
    self.handle = handle;

    // Create the channel
    const channel = Channel.init(
        safe_context,
        Container.onInspectorResponse,
        Container.onInspectorEvent,
        Container.onRunMessageLoopOnPause,
        Container.onQuitMessageLoopOnPause,
        isolate,
    );
    self.channel = channel;
    channel.setInspector(self);

    // Create the session
    const session_handle = v8.v8_inspector__Inspector__Connect(
        handle,
        CONTEXT_GROUP_ID,
        channel.handle,
        CLIENT_TRUST_LEVEL,
    ).?;
    self.session = .{ .handle = session_handle };
}

pub fn deinit(self: *const Inspector) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    self.session.deinit();
    self.client.deinit();
    self.channel.deinit();
    v8.v8_inspector__Inspector__DELETE(self.handle);
}

pub fn send(self: *const Inspector, msg: []const u8) void {
    // Can't assume the main Context exists (with its HandleScope)
    // available when doing this. Pages (and thus the HandleScope)
    // comes and goes, but CDP can keep sending messages.
    const isolate = self.isolate;
    var temp_scope: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&temp_scope, isolate);
    defer v8.v8__HandleScope__DESTRUCT(&temp_scope);

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
    self: *Inspector,
    local: *const js.Local,
    name: []const u8,
    origin: []const u8,
    aux_data: []const u8,
    is_default_context: bool,
) void {
    v8.v8_inspector__Inspector__ContextCreated(
        self.handle,
        name.ptr,
        name.len,
        origin.ptr,
        origin.len,
        aux_data.ptr,
        aux_data.len,
        CONTEXT_GROUP_ID,
        local.handle,
    );

    if (is_default_context) {
        self.default_context = local.ctx.handle;
    }
}

// Retrieves the RemoteObject for a given value.
// The value is loaded through the ExecutionWorld's mapZigInstanceToJs function,
// just like a method return value. Therefore, if we've mapped this
// value before, we'll get the existing js.Global(js.Object) and if not
// we'll create it and track it for cleanup when the context ends.
pub fn getRemoteObject(
    self: *const Inspector,
    local: *const js.Local,
    group: []const u8,
    value: anytype,
) !RemoteObject {
    const js_val = try local.zigValueToJs(value, .{});

    // We do not want to expose this as a parameter for now
    const generate_preview = false;
    return self.session.wrapObject(
        local.isolate.handle,
        local.handle,
        js_val.handle,
        group,
        generate_preview,
    );
}

// Gets a value by object ID regardless of which context it is in.
// Our TaggedAnyOpaque stores the "resolved" ptr value (the most specific _type,
// e.g. we store the ptr to the Div not the EventTarget). But, this is asking for
// the pointer to the Node, so we need to use the same resolution mechanism which
// is used when we're calling a function to turn the Div into a Node, which is
// what Context.typeTaggedAnyOpaque does.
pub fn getNodePtr(self: *const Inspector, allocator: Allocator, object_id: []const u8) !*anyopaque {
    const unwrapped = try self.session.unwrapObject(allocator, object_id);
    // The values context and groupId are not used here
    const js_val = unwrapped.value;
    if (!v8.v8__Value__IsObject(js_val)) {
        return error.ObjectIdIsNotANode;
    }

    const Node = @import("../webapi/Node.zig");
    // Cast to *const v8.Object for typeTaggedAnyOpaque
    return TaggedOpaque.fromJS(*Node, @ptrCast(js_val)) catch return error.ObjectIdIsNotANode;
}

pub const RemoteObject = struct {
    handle: *v8.RemoteObject,

    pub fn deinit(self: RemoteObject) void {
        v8.v8_inspector__RemoteObject__DELETE(self.handle);
    }

    pub fn getType(self: RemoteObject, allocator: Allocator) ![]const u8 {
        var ctype_: v8.CZigString = .{ .ptr = null, .len = 0 };
        if (!v8.v8_inspector__RemoteObject__getType(self.handle, &allocator, &ctype_)) return error.V8AllocFailed;
        return cZigStringToString(ctype_) orelse return error.InvalidType;
    }

    pub fn getSubtype(self: RemoteObject, allocator: Allocator) !?[]const u8 {
        if (!v8.v8_inspector__RemoteObject__hasSubtype(self.handle)) return null;

        var csubtype: v8.CZigString = .{ .ptr = null, .len = 0 };
        if (!v8.v8_inspector__RemoteObject__getSubtype(self.handle, &allocator, &csubtype)) return error.V8AllocFailed;
        return cZigStringToString(csubtype);
    }

    pub fn getClassName(self: RemoteObject, allocator: Allocator) !?[]const u8 {
        if (!v8.v8_inspector__RemoteObject__hasClassName(self.handle)) return null;

        var cclass_name: v8.CZigString = .{ .ptr = null, .len = 0 };
        if (!v8.v8_inspector__RemoteObject__getClassName(self.handle, &allocator, &cclass_name)) return error.V8AllocFailed;
        return cZigStringToString(cclass_name);
    }

    pub fn getDescription(self: RemoteObject, allocator: Allocator) !?[]const u8 {
        if (!v8.v8_inspector__RemoteObject__hasDescription(self.handle)) return null;

        var description: v8.CZigString = .{ .ptr = null, .len = 0 };
        if (!v8.v8_inspector__RemoteObject__getDescription(self.handle, &allocator, &description)) return error.V8AllocFailed;
        return cZigStringToString(description);
    }

    pub fn getObjectId(self: RemoteObject, allocator: Allocator) !?[]const u8 {
        if (!v8.v8_inspector__RemoteObject__hasObjectId(self.handle)) return null;

        var cobject_id: v8.CZigString = .{ .ptr = null, .len = 0 };
        if (!v8.v8_inspector__RemoteObject__getObjectId(self.handle, &allocator, &cobject_id)) return error.V8AllocFailed;
        return cZigStringToString(cobject_id);
    }
};

const Session = struct {
    handle: *v8.InspectorSession,

    fn deinit(self: Session) void {
        v8.v8_inspector__Session__DELETE(self.handle);
    }

    fn dispatchProtocolMessage(self: Session, isolate: *v8.Isolate, msg: []const u8) void {
        v8.v8_inspector__Session__dispatchProtocolMessage(
            self.handle,
            isolate,
            msg.ptr,
            msg.len,
        );
    }

    fn wrapObject(
        self: Session,
        isolate: *v8.Isolate,
        ctx: *const v8.Context,
        val: *const v8.Value,
        grpname: []const u8,
        generatepreview: bool,
    ) !RemoteObject {
        const remote_object = v8.v8_inspector__Session__wrapObject(
            self.handle,
            isolate,
            ctx,
            val,
            grpname.ptr,
            grpname.len,
            generatepreview,
        ).?;
        return .{ .handle = remote_object };
    }

    fn unwrapObject(
        self: Session,
        allocator: Allocator,
        object_id: []const u8,
    ) !UnwrappedObject {
        const in_object_id = v8.CZigString{
            .ptr = object_id.ptr,
            .len = object_id.len,
        };
        var out_error: v8.CZigString = .{ .ptr = null, .len = 0 };
        var out_value_handle: ?*v8.Value = null;
        var out_context_handle: ?*v8.Context = null;
        var out_object_group: v8.CZigString = .{ .ptr = null, .len = 0 };

        const result = v8.v8_inspector__Session__unwrapObject(
            self.handle,
            &allocator,
            &out_error,
            in_object_id,
            &out_value_handle,
            &out_context_handle,
            &out_object_group,
        );

        if (!result) {
            const error_str = cZigStringToString(out_error) orelse return error.UnwrapFailed;
            std.log.err("unwrapObject failed: {s}", .{error_str});
            return error.UnwrapFailed;
        }

        return .{
            .value = out_value_handle.?,
            .context = out_context_handle.?,
            .object_group = cZigStringToString(out_object_group),
        };
    }
};

const UnwrappedObject = struct {
    value: *const v8.Value,
    context: *const v8.Context,
    object_group: ?[]const u8,
};

const Channel = struct {
    handle: *v8.InspectorChannelImpl,

    // callbacks
    ctx: *anyopaque,
    onNotif: onNotifFn = undefined,
    onResp: onRespFn = undefined,
    onRunMessageLoopOnPause: onRunMessageLoopOnPauseFn = undefined,
    onQuitMessageLoopOnPause: onQuitMessageLoopOnPauseFn = undefined,

    pub const onNotifFn = *const fn (ctx: *anyopaque, msg: []const u8) void;
    pub const onRespFn = *const fn (ctx: *anyopaque, call_id: u32, msg: []const u8) void;
    pub const onRunMessageLoopOnPauseFn = *const fn (ctx: *anyopaque, context_group_id: u32) void;
    pub const onQuitMessageLoopOnPauseFn = *const fn (ctx: *anyopaque) void;

    fn init(
        ctx: *anyopaque,
        onResp: onRespFn,
        onNotif: onNotifFn,
        onRunMessageLoopOnPause: onRunMessageLoopOnPauseFn,
        onQuitMessageLoopOnPause: onQuitMessageLoopOnPauseFn,
        isolate: *v8.Isolate,
    ) Channel {
        const handle = v8.v8_inspector__Channel__IMPL__CREATE(isolate);
        return .{
            .handle = handle,
            .ctx = ctx,
            .onResp = onResp,
            .onNotif = onNotif,
            .onRunMessageLoopOnPause = onRunMessageLoopOnPause,
            .onQuitMessageLoopOnPause = onQuitMessageLoopOnPause,
        };
    }

    fn deinit(self: Channel) void {
        v8.v8_inspector__Channel__IMPL__DELETE(self.handle);
    }

    fn setInspector(self: Channel, inspector: *anyopaque) void {
        v8.v8_inspector__Channel__IMPL__SET_DATA(self.handle, inspector);
    }

    fn resp(self: Channel, call_id: u32, msg: []const u8) void {
        self.onResp(self.ctx, call_id, msg);
    }

    fn notif(self: Channel, msg: []const u8) void {
        self.onNotif(self.ctx, msg);
    }
};

const Client = struct {
    handle: *v8.InspectorClientImpl,

    fn init() Client {
        return .{ .handle = v8.v8_inspector__Client__IMPL__CREATE() };
    }

    fn deinit(self: Client) void {
        v8.v8_inspector__Client__IMPL__DELETE(self.handle);
    }

    fn setInspector(self: Client, inspector: *anyopaque) void {
        v8.v8_inspector__Client__IMPL__SET_DATA(self.handle, inspector);
    }
};

const NoopInspector = struct {
    pub fn onInspectorResponse(_: *anyopaque, _: u32, _: []const u8) void {}
    pub fn onInspectorEvent(_: *anyopaque, _: []const u8) void {}
    pub fn onRunMessageLoopOnPause(_: *anyopaque, _: u32) void {}
    pub fn onQuitMessageLoopOnPause(_: *anyopaque) void {}
};

fn fromData(data: *anyopaque) *Inspector {
    return @ptrCast(@alignCast(data));
}

pub fn getTaggedOpaque(value: *const v8.Value) ?*TaggedOpaque {
    if (!v8.v8__Value__IsObject(value)) {
        return null;
    }
    const internal_field_count = v8.v8__Object__InternalFieldCount(value);
    if (internal_field_count == 0) {
        return null;
    }

    const external_value = v8.v8__Object__GetInternalField(value, 0).?;
    const external_data = v8.v8__External__Value(external_value).?;
    return @ptrCast(@alignCast(external_data));
}

fn cZigStringToString(s: v8.CZigString) ?[]const u8 {
    if (s.ptr == null) return null;
    return s.ptr[0..s.len];
}

// C export functions for Inspector callbacks
pub export fn v8_inspector__Client__IMPL__generateUniqueId(
    _: *v8.InspectorClientImpl,
    data: *anyopaque,
) callconv(.c) i64 {
    const inspector: *Inspector = @ptrCast(@alignCast(data));
    return inspector.rnd.random().int(i64);
}

pub export fn v8_inspector__Client__IMPL__runMessageLoopOnPause(
    _: *v8.InspectorClientImpl,
    data: *anyopaque,
    ctx_group_id: c_int,
) callconv(.c) void {
    const inspector: *Inspector = @ptrCast(@alignCast(data));
    inspector.channel.onRunMessageLoopOnPause(inspector.channel.ctx, @intCast(ctx_group_id));
}

pub export fn v8_inspector__Client__IMPL__quitMessageLoopOnPause(
    _: *v8.InspectorClientImpl,
    data: *anyopaque,
) callconv(.c) void {
    const inspector: *Inspector = @ptrCast(@alignCast(data));
    inspector.channel.onQuitMessageLoopOnPause(inspector.channel.ctx);
}

pub export fn v8_inspector__Client__IMPL__runIfWaitingForDebugger(
    _: *v8.InspectorClientImpl,
    _: *anyopaque,
    _: c_int,
) callconv(.c) void {
    // TODO
}

pub export fn v8_inspector__Client__IMPL__consoleAPIMessage(
    _: *v8.InspectorClientImpl,
    _: *anyopaque,
    _: c_int,
    _: v8.MessageErrorLevel,
    _: *v8.StringView,
    _: *v8.StringView,
    _: c_uint,
    _: c_uint,
    _: *v8.StackTrace,
) callconv(.c) void {}

pub export fn v8_inspector__Client__IMPL__ensureDefaultContextInGroup(
    _: *v8.InspectorClientImpl,
    data: *anyopaque,
) callconv(.c) ?*const v8.Context {
    const inspector: *Inspector = @ptrCast(@alignCast(data));
    const global_handle = inspector.default_context orelse return null;
    return v8.v8__Global__Get(&global_handle, inspector.isolate);
}

pub export fn v8_inspector__Channel__IMPL__sendResponse(
    _: *v8.InspectorChannelImpl,
    data: *anyopaque,
    call_id: c_int,
    msg: [*c]u8,
    length: usize,
) callconv(.c) void {
    const inspector: *Inspector = @ptrCast(@alignCast(data));
    inspector.channel.resp(@as(u32, @intCast(call_id)), msg[0..length]);
}

pub export fn v8_inspector__Channel__IMPL__sendNotification(
    _: *v8.InspectorChannelImpl,
    data: *anyopaque,
    msg: [*c]u8,
    length: usize,
) callconv(.c) void {
    const inspector: *Inspector = @ptrCast(@alignCast(data));
    inspector.channel.notif(msg[0..length]);
}

pub export fn v8_inspector__Channel__IMPL__flushProtocolNotifications(
    _: *v8.InspectorChannelImpl,
    _: *anyopaque,
) callconv(.c) void {
    // TODO
}

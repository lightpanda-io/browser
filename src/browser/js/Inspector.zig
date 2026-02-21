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

const CONTEXT_GROUP_ID = 1;
const CLIENT_TRUST_LEVEL = 1;
const IS_DEBUG = @import("builtin").mode == .Debug;

// Inspector exists for the lifetime of the Isolate/Env. 1 Isolate = 1 Inspector.
// It combines the v8.Inspector and the v8.InspectorClientImpl. The v8.InspectorClientImpl
// is our own implementation that fulfills the InspectorClient API, i.e. it's the
// mechanism v8 provides to let us tweak how the inspector works. For example, it
// Below, you'll find a few pub export fn v8_inspector__Client__IMPL__XYZ functions
// which is our implementation of what the v8::Inspector requires of our Client
// (not much at all)
const Inspector = @This();

unique_id: i64,
isolate: *v8.Isolate,
handle: *v8.Inspector,
client: *v8.InspectorClientImpl,
default_context: ?v8.Global,
session: ?Session,

pub fn init(allocator: Allocator, isolate: *v8.Isolate) !*Inspector {
    const self = try allocator.create(Inspector);
    errdefer allocator.destroy(self);

    self.* = .{
        .unique_id = 1,
        .session = null,
        .isolate = isolate,
        .client = undefined,
        .handle = undefined,
        .default_context = null,
    };

    self.client = v8.v8_inspector__Client__IMPL__CREATE();
    errdefer v8.v8_inspector__Client__IMPL__DELETE(self.client);
    v8.v8_inspector__Client__IMPL__SET_DATA(self.client, self);

    self.handle = v8.v8_inspector__Inspector__Create(isolate, self.client).?;
    errdefer v8.v8_inspector__Inspector__DELETE(self.handle);

    return self;
}

pub fn deinit(self: *const Inspector, allocator: Allocator) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    if (self.session) |*s| {
        s.deinit();
    }
    v8.v8_inspector__Client__IMPL__DELETE(self.client);
    v8.v8_inspector__Inspector__DELETE(self.handle);
    allocator.destroy(self);
}

pub fn startSession(self: *Inspector, ctx: anytype) *Session {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.session == null);
    }

    self.session = @as(Session, undefined);
    Session.init(&self.session.?, self, ctx);
    return &self.session.?;
}

pub fn stopSession(self: *Inspector) void {
    self.session.?.deinit();
    self.session = null;
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

pub fn contextDestroyed(self: *Inspector, context: *const v8.Context) void {
    v8.v8_inspector__Inspector__ContextDestroyed(self.handle, context);
}

pub fn resetContextGroup(self: *const Inspector) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    v8.v8_inspector__Inspector__ResetContextGroup(self.handle, CONTEXT_GROUP_ID);
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

// Combines a v8::InspectorSession and a v8::InspectorChannelImpl. The
// InspectorSession is for zig -> v8 (sending messages to the inspector). The
// Channel is for v8 -> zig, getting events from the Inspector (that we'll pass
// back ot some opaque context, i.e the CDP BrowserContext).
// The channel callbacks are defined below, as:
//   pub export fn v8_inspector__Channel__IMPL__XYZ
pub const Session = struct {
    inspector: *Inspector,
    handle: *v8.InspectorSession,
    channel: *v8.InspectorChannelImpl,

    // callbacks
    ctx: *anyopaque,
    onNotif: *const fn (ctx: *anyopaque, msg: []const u8) void,
    onResp: *const fn (ctx: *anyopaque, call_id: u32, msg: []const u8) void,

    fn init(self: *Session, inspector: *Inspector, ctx: anytype) void {
        const Container = @typeInfo(@TypeOf(ctx)).pointer.child;

        const channel = v8.v8_inspector__Channel__IMPL__CREATE(inspector.isolate);
        const handle = v8.v8_inspector__Inspector__Connect(
            inspector.handle,
            CONTEXT_GROUP_ID,
            channel,
            CLIENT_TRUST_LEVEL,
        ).?;
        v8.v8_inspector__Channel__IMPL__SET_DATA(channel, self);

        self.* = .{
            .ctx = ctx,
            .handle = handle,
            .channel = channel,
            .inspector = inspector,
            .onResp = Container.onInspectorResponse,
            .onNotif = Container.onInspectorEvent,
        };
    }

    fn deinit(self: *const Session) void {
        v8.v8_inspector__Session__DELETE(self.handle);
        v8.v8_inspector__Channel__IMPL__DELETE(self.channel);
    }

    pub fn send(self: *const Session, msg: []const u8) void {
        const isolate = self.inspector.isolate;
        var hs: v8.HandleScope = undefined;
        v8.v8__HandleScope__CONSTRUCT(&hs, isolate);
        defer v8.v8__HandleScope__DESTRUCT(&hs);

        v8.v8_inspector__Session__dispatchProtocolMessage(
            self.handle,
            isolate,
            msg.ptr,
            msg.len,
        );
    }

    // Gets a value by object ID regardless of which context it is in.
    // Our TaggedOpaque stores the "resolved" ptr value (the most specific _type,
    // e.g. we store the ptr to the Div not the EventTarget). But, this is asking for
    // the pointer to the Node, so we need to use the same resolution mechanism which
    // is used when we're calling a function to turn the Div into a Node, which is
    // what TaggedOpaque.fromJS does.
    pub fn getNodePtr(self: *const Session, allocator: Allocator, object_id: []const u8, local: *js.Local) !*anyopaque {
        // just to indicate that the caller is responsible for ensuring there's a local environment
        _ = local;

        const unwrapped = try self.unwrapObject(allocator, object_id);
        // The values context and groupId are not used here
        const js_val = unwrapped.value;
        if (!v8.v8__Value__IsObject(js_val)) {
            return error.ObjectIdIsNotANode;
        }

        const Node = @import("../webapi/Node.zig");
        // Cast to *const v8.Object for typeTaggedAnyOpaque
        return TaggedOpaque.fromJS(*Node, @ptrCast(js_val)) catch return error.ObjectIdIsNotANode;
    }

    // Retrieves the RemoteObject for a given value.
    // The value is loaded through the ExecutionWorld's mapZigInstanceToJs function,
    // just like a method return value. Therefore, if we've mapped this
    // value before, we'll get the existing js.Global(js.Object) and if not
    // we'll create it and track it for cleanup when the context ends.
    pub fn getRemoteObject(
        self: *const Session,
        local: *const js.Local,
        group: []const u8,
        value: anytype,
    ) !RemoteObject {
        const js_val = try local.zigValueToJs(value, .{});

        // We do not want to expose this as a parameter for now
        const generate_preview = false;
        return self.wrapObject(
            local.isolate.handle,
            local.handle,
            js_val.handle,
            group,
            generate_preview,
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

pub fn getTaggedOpaque(value: *const v8.Value) ?*TaggedOpaque {
    if (!v8.v8__Value__IsObject(value)) {
        return null;
    }
    const internal_field_count = v8.v8__Object__InternalFieldCount(value);
    if (internal_field_count == 0) {
        return null;
    }

    const tao_ptr = v8.v8__Object__GetAlignedPointerFromInternalField(value, 0).?;
    return @ptrCast(@alignCast(tao_ptr));
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
    const unique_id = inspector.unique_id + 1;
    inspector.unique_id = unique_id;
    return unique_id;
}

pub export fn v8_inspector__Client__IMPL__runMessageLoopOnPause(
    _: *v8.InspectorClientImpl,
    data: *anyopaque,
    context_group_id: c_int,
) callconv(.c) void {
    _ = data;
    _ = context_group_id;
}

pub export fn v8_inspector__Client__IMPL__quitMessageLoopOnPause(
    _: *v8.InspectorClientImpl,
    data: *anyopaque,
) callconv(.c) void {
    _ = data;
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
    const session: *Session = @ptrCast(@alignCast(data));
    session.onResp(session.ctx, @intCast(call_id), msg[0..length]);
}

pub export fn v8_inspector__Channel__IMPL__sendNotification(
    _: *v8.InspectorChannelImpl,
    data: *anyopaque,
    msg: [*c]u8,
    length: usize,
) callconv(.c) void {
    const session: *Session = @ptrCast(@alignCast(data));
    session.onNotif(session.ctx, msg[0..length]);
}

pub export fn v8_inspector__Channel__IMPL__flushProtocolNotifications(
    _: *v8.InspectorChannelImpl,
    _: *anyopaque,
) callconv(.c) void {
    // TODO
}

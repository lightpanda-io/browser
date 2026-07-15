// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const string = @import("../../string.zig");

const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");

const js = @import("js.zig");
const Local = @import("Local.zig");
const Context = @import("Context.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const log = lp.log;
const ArenaAllocator = std.heap.ArenaAllocator;
const CALL_ARENA_RETAIN = 1024 * 16;
const LOCAL_ARENA_RETAIN = 1024 * 16;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Caller = @This();

local: Local,
prev_local: ?*const js.Local,
prev_context: *Context,

// Takes the raw v8 isolate and extracts the context from it.
// Returns false if the context has been destroyed (e.g., navigated-away iframe),
// in which case a JS exception has been thrown and the caller should return immediately.
pub fn init(self: *Caller, v8_isolate: *v8.Isolate) bool {
    const ctx, const v8_context = Context.fromIsolate(.{ .handle = v8_isolate }) orelse {
        throwDetachedError(v8_isolate);
        return false;
    };
    initWithContext(self, ctx, v8_context);
    return true;
}

fn throwDetachedError(isolate: *v8.Isolate) void {
    const message = "Cannot execute in detached context (e.g., navigated-away iframe)";
    const v8_message = v8.v8__String__NewFromUtf8(isolate, message.ptr, v8.kNormal, @intCast(message.len));
    const js_exception = v8.v8__Exception__Error(v8_message);
    _ = v8.v8__Isolate__ThrowException(isolate, js_exception);
}

pub fn initWithContext(self: *Caller, ctx: *Context, v8_context: *const v8.Context) void {
    ctx.call_depth += 1;
    self.* = Caller{
        .local = .{
            .ctx = ctx,
            .handle = v8_context,
            .call_arena = ctx.call_arena,
            .isolate = ctx.isolate,
        },
        .prev_local = ctx.local,
        .prev_context = ctx.global.getJs(),
    };
    ctx.global.setJs(ctx);
    ctx.local = &self.local;
}

pub fn initFromHandle(self: *Caller, handle: ?*const v8.FunctionCallbackInfo) bool {
    const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
    return self.init(isolate);
}

pub fn deinit(self: *Caller) void {
    const ctx = self.local.ctx;
    const call_depth = ctx.call_depth - 1;

    // Because of callbacks, calls can be nested. Because of this, we
    // can't clear the call_arena after _every_ call. Imagine we have
    //    arr.forEach((i) => { console.log(i); }
    //
    // First we call forEach. Inside of our forEach call,
    // we call console.log. If we reset the call_arena after this call,
    // it'll reset it for the `forEach` call after, which might still
    // need the data.
    //
    // Therefore, we keep a call_depth, and only reset the call_arena
    // when a top-level (call_depth == 0) function ends.
    if (call_depth == 0) {
        const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx.call_arena.ptr));
        _ = arena.reset(.{ .retain_with_limit = CALL_ARENA_RETAIN });
    }

    // Unlike call_arena, local_arena is reset on _every_ return, since its
    // users promise not to hold data across a nested call. In debug, free
    // back to the backing allocator so a stale pointer trips the
    // DebugAllocator's use-after-free detection; in release, retain a buffer
    // to avoid realloc churn.
    {
        const local_arena: *ArenaAllocator = @ptrCast(@alignCast(ctx.local_arena.ptr));
        _ = local_arena.reset(if (comptime IS_DEBUG) .free_all else .{ .retain_with_limit = LOCAL_ARENA_RETAIN });
    }

    ctx.call_depth = call_depth;
    ctx.local = self.prev_local;
    ctx.global.setJs(self.prev_context);
}

pub const CallOpts = struct {
    null_as_undefined: bool = false,
    as_typed_array: bool = false,
    // Constructor-only. When true, `new.target` is pulled from the
    // FunctionCallbackInfo and passed as the first argument to the Zig
    // function (as a js.Function). See bridge.Constructor.Opts.
    new_target: bool = false,
};

pub fn constructor(self: *Caller, comptime T: type, func: anytype, handle: *const v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = FunctionCallbackInfo{ .handle = handle };

    if (!info.isConstructCall()) {
        handleError(T, @TypeOf(func), local, error.InvalidArgument, info);
        return;
    }

    self._constructor(func, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
    };
}

fn _constructor(self: *Caller, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) !void {
    const F = @TypeOf(func);
    const local = &self.local;
    const offset: comptime_int = if (opts.new_target) 1 else 0;
    var args = try getArgs(F, offset, local, info);
    if (comptime opts.new_target) {
        const new_target_handle = v8.v8__FunctionCallbackInfo__NewTarget(info.handle).?;
        @field(args, "0") = js.Function{ .local = local, .handle = @ptrCast(new_target_handle) };
    }
    const res = @call(.auto, func, args);

    const ReturnType = @typeInfo(F).@"fn".return_type orelse {
        @compileError(@typeName(F) ++ " has a constructor without a return type");
    };

    const new_this_handle = info.getThis();
    var this = js.Object{ .local = local, .handle = new_this_handle };
    if (@typeInfo(ReturnType) == .error_union) {
        const non_error_res = try res;
        this = try local.mapZigInstanceToJs(new_this_handle, non_error_res);
    } else {
        this = try local.mapZigInstanceToJs(new_this_handle, res);
    }

    // If we got back a different object (existing wrapper), copy the prototype
    // from new object. (this happens when we're upgrading an CustomElement)
    if (this.handle != new_this_handle) {
        const prototype_handle = v8.v8__Object__GetPrototype(new_this_handle).?;
        var out: v8.MaybeBool = undefined;
        v8.v8__Object__SetPrototype(this.handle, self.local.handle, prototype_handle, &out);
        if (comptime IS_DEBUG) {
            std.debug.assert(out.has_value and out.value);
        }
    }

    info.getReturnValue().set(this.handle);
}

pub fn getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getIndex(T, local, func, idx, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _getIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getNamedIndex(T, local, func, name, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _getNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn setIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, js_value: *const v8.Value, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _setIndex(T, local, func, idx, .{ .local = &self.local, .handle = js_value }, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _setIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, js_value: js.Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    @field(args, "2") = try local.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = getGlobalArg(@TypeOf(args.@"3"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, comptime returnsBool(F), local, ret, info, opts);
}

pub fn deleteOrDefineIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _deleteOrDefineIndex(T, local, func, idx, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _deleteOrDefineIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, comptime returnsBool(F), local, ret, info, opts);
}

pub fn setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, js_value: *const v8.Value, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _setNamedIndex(T, local, func, name, .{ .local = &self.local, .handle = js_value }, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _setNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, js_value: js.Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    @field(args, "2") = try local.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = getGlobalArg(@TypeOf(args.@"3"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, comptime returnsBool(F), local, ret, info, opts);
}

pub fn deleteOrDefineNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _deleteOrDefineNamedIndex(T, local, func, name, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _deleteOrDefineNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, comptime returnsBool(F), local, ret, info, opts);
}

pub fn getEnumerator(self: *Caller, comptime T: type, func: anytype, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getEnumerator(T, local, func, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _getEnumerator(comptime T: type, local: *const Local, func: anytype, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    if (@typeInfo(F).@"fn".params.len == 2) {
        @field(args, "1") = getGlobalArg(@TypeOf(args.@"1"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn getIndexQuery(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getIndexQuery(T, local, func, idx, info) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _getIndexQuery(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    return queryReturn(local, @call(.auto, func, args), info);
}

pub fn getNamedQuery(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getNamedQuery(T, local, func, name, info) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.no;
    };
}

fn _getNamedQuery(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    return queryReturn(local, @call(.auto, func, args), info);
}

// A query callback either returns a bool (true -> the property exists as an
// enumerable, writable, configurable data property, PropertyAttribute.None)
// or the v8.PropertyAttribute bits directly (e.g. v8.ReadOnly).
// error.NotHandled falls through to the ordinary property lookup.
fn queryReturn(local: *const Local, ret: anytype, info: PropertyCallbackInfo) !u32 {
    const val = switch (@typeInfo(@TypeOf(ret))) {
        .error_union => |eu| ret catch |err| {
            if (comptime isInErrorSet(error.NotHandled, eu.error_set)) {
                if (err == error.NotHandled) {
                    return js.Intercepted.no;
                }
            }
            return err;
        },
        else => ret,
    };
    if (@TypeOf(val) == bool) {
        if (val == false) {
            return js.Intercepted.no;
        }
        info.getReturnValue().set(try local.zigValueToJs(@as(u32, v8.None), .{}));
    } else {
        info.getReturnValue().set(try local.zigValueToJs(@as(u32, val), .{}));
    }
    return js.Intercepted.yes;
}

fn handleIndexedReturn(comptime T: type, comptime F: type, comptime with_value: bool, local: *const Local, ret: anytype, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    // need to unwrap this error immediately for when opts.null_as_undefined == true
    // and we need to compare it to null;
    const non_error_ret = switch (@typeInfo(@TypeOf(ret))) {
        .error_union => |eu| blk: {
            break :blk ret catch |err| {
                // We can't compare err == error.NotHandled if error.NotHandled
                // isn't part of the possible error set. So we first need to check
                // if error.NotHandled is part of the error set.
                if (isInErrorSet(error.NotHandled, eu.error_set)) {
                    if (err == error.NotHandled) {
                        return js.Intercepted.no;
                    }
                }
                handleError(T, F, local, err, info);
                return js.Intercepted.no;
            };
        },
        else => ret,
    };

    if (comptime with_value) {
        info.getReturnValue().set(try local.zigValueToJs(non_error_ret, opts));
    }
    return js.Intercepted.yes;
}

// Setter/deleter interceptors normally return void: intercepting is enough
// to mark the operation successful. When they return a bool instead, it is
// forwarded as the v8 return value; false marks the operation as failed,
// which makes v8 throw a TypeError in strict mode.
fn returnsBool(comptime F: type) bool {
    const RT = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(RT)) {
        .error_union => |eu| eu.payload == bool,
        else => RT == bool,
    };
}

fn isInErrorSet(err: anyerror, comptime T: type) bool {
    inline for (@typeInfo(T).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

fn nameToString(local: *const Local, comptime T: type, name: *const v8.Name) !T {
    const handle = @as(*const v8.String, @ptrCast(name));
    if (T == string.String) {
        return js.String.toSSO(.{ .local = local, .handle = handle }, false);
    }
    if (T == string.Global) {
        return js.String.toSSO(.{ .local = local, .handle = handle }, true);
    }
    return try js.String.toSlice(.{ .local = local, .handle = handle });
}

// Per Web IDL, exceptions belong to the operation's relevant realm — the
// receiver's — which differs from the calling realm for cross-realm calls
// (v8 API callbacks run in the caller's context, and our JS wrappers are
// shared across the page's contexts). For DOM nodes, the relevant realm is
// the node document's frame; otherwise fall back to the calling realm.
fn errorLocal(comptime T: type, local: *const Local, info: anytype) Local {
    if (@TypeOf(info) != FunctionCallbackInfo) {
        return local.*;
    }

    const frame = switch (local.ctx.global) {
        .frame => |f| f,
        .worker => return local.*,
    };

    const Node = @import("../webapi/Node.zig");
    const Document = @import("../webapi/Document.zig");

    const is_node_type = comptime blk: {
        if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "JsApi")) break :blk false;
        break :blk @import("bridge.zig").inheritsOrIs(T.JsApi, Node.JsApi);
    };
    if (comptime !is_node_type) {
        return local.*;
    }

    const instance = TaggedOpaque.fromJS(*T, info.getThis()) catch return local.*;
    const node = protoNode(T, instance);

    const doc: *Document = node.ownerDocument(frame) orelse switch (node._type) {
        .document => |d| d,
        else => return local.*,
    };
    const doc_frame = doc._frame orelse return local.*;
    if (doc_frame == frame) {
        return local.*;
    }

    const ctx = doc_frame.js;
    const local_v8_context: *const v8.Context = @ptrCast(v8.v8__Global__Get(&ctx.handle, ctx.isolate.handle) orelse return local.*);
    return .{
        .ctx = ctx,
        .handle = local_v8_context,
        .call_arena = ctx.call_arena,
        .isolate = ctx.isolate,
    };
}

// Upcast a Node-descendant instance to *Node by walking the _proto chain.
// Not every node type defines an asNode() helper (e.g. Comment, Text), but
// inheritsOrIs guarantees Node is in the chain
fn protoNode(comptime T: type, instance: *T) *@import("../webapi/Node.zig") {
    if (T == @import("../webapi/Node.zig")) {
        return instance;
    }
    const Proto = @typeInfo(std.meta.fieldInfo(T, ._proto).type).pointer.child;
    return protoNode(Proto, instance._proto);
}

fn handleError(comptime T: type, comptime F: type, local: *const Local, err: anyerror, info: anytype) void {
    const isolate = local.isolate;

    if (comptime IS_DEBUG and @TypeOf(info) == FunctionCallbackInfo) {
        if (log.enabled(.js, .debug)) {
            const DOMException = @import("../webapi/DOMException.zig");
            if (DOMException.fromError(err) == null) {
                // This isn't a DOMException, let's log it
                logFunctionCallError(local, @typeName(T), @typeName(F), err, info);
            }
        }
    }

    // early exit
    switch (err) {
        error.TryCatchRethrow => return,
        // A JS exception is already pending in the isolate (e.g. a value's
        // toString threw during argument conversion); throwing anything here
        // would replace the original exception the script expects to see.
        error.JsException => return,
        else => {},
    }

    const err_local = errorLocal(T, local, info);

    const js_err: *const v8.Value = blk: {
        // Error constructors use the isolate's current context: enter the
        // receiver's realm so the exception gets its prototypes.
        const entered = err_local.ctx != local.ctx;
        if (entered) v8.v8__Context__Enter(err_local.handle);
        defer if (entered) v8.v8__Context__Exit(err_local.handle);

        break :blk switch (err) {
            error.InvalidArgument => isolate.createTypeError("invalid argument"),
            error.TypeError => isolate.createTypeError(""),
            error.RangeError => isolate.createRangeError(""),
            error.OutOfMemory => isolate.createError("out of memory"),
            error.IllegalConstructor => isolate.createError("Illegal Constructor"),
            error.TryCatchRethrow, error.JsException => unreachable, // early exited a few lines up
            else => domExceptionToJs(&err_local, err) orelse isolate.createError(@errorName(err)),
        };
    };

    const js_exception = isolate.throwException(js_err);
    info.getReturnValue().setValueHandle(js_exception);
}

// Convert a Zig error to a DOMException. If the error is unknown, return null.
fn domExceptionToJs(local: *const Local, err: anyerror) ?*const v8.Value {
    const DOMException = @import("../webapi/DOMException.zig");
    const ex = DOMException.fromError(err) orelse return null;
    const value = local.zigValueToJs(ex, .{}) catch return local.isolate.createError("internal error");
    return value.handle;
}

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(local: *const Local, type_name: []const u8, func: []const u8, err: anyerror, info: FunctionCallbackInfo) void {
    const args_dump = serializeFunctionArgs(local, info) catch "failed to serialize args";
    log.debug(.js, "function call error", .{
        .type = type_name,
        .func = func,
        .err = err,
        .args = args_dump,
        .stack = local.stackTrace() catch |err1| @errorName(err1),
    });
}

fn serializeFunctionArgs(local: *const Local, info: FunctionCallbackInfo) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(local.call_arena);

    const separator = log.separator();
    for (0..info.length()) |i| {
        try buf.writer.print("{s}{d} - ", .{ separator, i + 1 });
        const js_value = info.getArg(@intCast(i), local);
        try local.debugValue(js_value, &buf.writer);
    }
    return buf.written();
}

// Takes a function, and returns a tuple for its argument. Used when we
// @call a function
fn ParameterTypes(comptime F: type) type {
    const params = @typeInfo(F).@"fn".params;
    var fields: [params.len]std.builtin.Type.StructField = undefined;

    inline for (params, 0..) |param, i| {
        fields[i] = .{
            .name = tupleFieldName(i),
            .type = param.type.?,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(param.type.?),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .decls = &.{},
        .fields = &fields,
        .is_tuple = true,
    } });
}

fn tupleFieldName(comptime i: usize) [:0]const u8 {
    return switch (i) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        else => std.fmt.comptimePrint("{d}", .{i}),
    };
}

fn isFrame(comptime T: type) bool {
    return T == *Frame or T == *const Frame;
}

fn isPage(comptime T: type) bool {
    return T == *Page or T == *const Page;
}

fn isSession(comptime T: type) bool {
    return T == *Session or T == *const Session;
}

fn isExecution(comptime T: type) bool {
    return T == *js.Execution or T == *const js.Execution;
}

fn getGlobalArg(comptime T: type, ctx: *Context) T {
    if (comptime isFrame(T)) {
        return switch (ctx.global) {
            .frame => |frame| frame,
            .worker => unreachable,
        };
    }

    if (comptime isPage(T)) {
        return ctx.page;
    }

    if (comptime isExecution(T)) {
        return &ctx.execution;
    }

    @compileError("Unsupported global arg type: " ++ @typeName(T));
}

// These wrap the raw v8 C API to provide a cleaner interface.
pub const FunctionCallbackInfo = struct {
    handle: *const v8.FunctionCallbackInfo,

    pub fn length(self: FunctionCallbackInfo) u32 {
        return @intCast(v8.v8__FunctionCallbackInfo__Length(self.handle));
    }

    pub fn getArg(self: FunctionCallbackInfo, index: u32, local: *const js.Local) js.Value {
        return .{ .local = local, .handle = v8.v8__FunctionCallbackInfo__INDEX(self.handle, @intCast(index)).? };
    }

    pub fn getData(self: FunctionCallbackInfo) ?*anyopaque {
        const data = v8.v8__FunctionCallbackInfo__Data(self.handle) orelse return null;
        return v8.v8__External__Value(@ptrCast(data));
    }

    pub fn getThis(self: FunctionCallbackInfo) *const v8.Object {
        return v8.v8__FunctionCallbackInfo__This(self.handle).?;
    }

    pub fn getReturnValue(self: FunctionCallbackInfo) ReturnValue {
        var rv: v8.ReturnValue = undefined;
        v8.v8__FunctionCallbackInfo__GetReturnValue(self.handle, &rv);
        return .{ .handle = rv };
    }

    fn isConstructCall(self: FunctionCallbackInfo) bool {
        return v8.v8__FunctionCallbackInfo__IsConstructCall(self.handle);
    }
};

pub const PropertyCallbackInfo = struct {
    handle: *const v8.PropertyCallbackInfo,

    pub fn getThis(self: PropertyCallbackInfo) *const v8.Object {
        return v8.v8__PropertyCallbackInfo__This(self.handle).?;
    }

    pub fn getReturnValue(self: PropertyCallbackInfo) ReturnValue {
        var rv: v8.ReturnValue = undefined;
        v8.v8__PropertyCallbackInfo__GetReturnValue(self.handle, &rv);
        return .{ .handle = rv };
    }
};

const ReturnValue = struct {
    handle: v8.ReturnValue,

    pub fn set(self: ReturnValue, value: anytype) void {
        const T = @TypeOf(value);
        if (T == *const v8.Object) {
            self.setValueHandle(@ptrCast(value));
        } else if (T == *const v8.Value) {
            self.setValueHandle(value);
        } else if (T == js.Value) {
            self.setValueHandle(value.handle);
        } else {
            @compileError("Unsupported type for ReturnValue.set: " ++ @typeName(T));
        }
    }

    pub fn setValueHandle(self: ReturnValue, handle: *const v8.Value) void {
        v8.v8__ReturnValue__Set(self.handle, handle);
    }
};

pub const Function = struct {
    pub const Opts = struct {
        noop: bool = false,
        static: bool = false,
        wpt_only: bool = false,
        deletable: bool = true,
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        cache: ?Caching = null,
        embedded_receiver: bool = false,
        exposed: Exposed = .both,
        ce_reactions: bool = false,
        js_name: ?[:0]const u8 = null,
        unforgeable: bool = false,

        pub const Exposed = enum { both, window, worker };

        // We support two ways to cache a value directly into a v8::Object. The
        // difference between the two is like the difference between a Map
        // and a Struct.
        // 1 - Using the object's internal fields. Think of this as
        //     adding a field to the struct. It's fast, but the space is reserved
        //     upfront for _every_ instance, whether we use it or not.
        //
        // 2 - Using the object's private state with a v8::Private key. Think of
        //     this as a HashMap. It takes no memory if the cache isn't used
        //     but has overhead when used.
        //
        // Consider `window.document`, (1) we have relatively few Window objects,
        // (2) They all have a document and (3) The document is accessed _a lot_.
        // An internal field makes sense.
        //
        // Consider `node.childNodes`, (1) we can have 20K+ node objects, (2)
        // 95% of nodes will never have their .childNodes access by JavaScript.
        // Private map lookup makes sense.
        pub const Caching = union(enum) {
            internal: u8,
            private: []const u8,
        };
    };

    pub fn call(comptime T: type, info_handle: *const v8.FunctionCallbackInfo, func: anytype, comptime opts: Opts) void {
        const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(info_handle).?;
        const ctx, const v8_context = Context.fromIsolate(.{ .handle = v8_isolate }) orelse {
            throwDetachedError(v8_isolate);
            return;
        };
        const info = FunctionCallbackInfo{ .handle = info_handle };

        var hs: js.HandleScope = undefined;
        hs.initWithIsolateHandle(v8_isolate);
        defer hs.deinit();

        var cache_state: CacheState = undefined;
        if (comptime opts.cache) |cache| {
            // This API is a bit weird. On
            if (respondFromCache(cache, ctx, v8_context, info, &cache_state)) {
                // Value was fetched from the cache and returned already
                return;
            } else {
                // Cache miss: cache_state will have been populated
            }
        }

        var caller: Caller = undefined;
        caller.initWithContext(ctx, v8_context);
        defer caller.deinit();

        // [CEReactions] entry: open a reactions scope so any custom-element
        // callbacks queued by DOM mutation inside `func` fire after it
        // returns, never mid-algorithm.
        var ce_checkpoint: usize = undefined;
        const ce_frame: ?*Frame = if (comptime opts.ce_reactions) switch (ctx.global) {
            .frame => |frame| frame,
            .worker => null,
        } else null;

        if (comptime opts.ce_reactions) {
            if (ce_frame) |frame| {
                ce_checkpoint = frame._ce_reactions.push();
            }
        }
        defer if (comptime opts.ce_reactions) {
            if (ce_frame) |frame| {
                frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);
            }
        };

        const js_value = _call(T, &caller.local, info, func, opts) catch |err| {
            handleError(T, @TypeOf(func), &caller.local, err, info);
            return;
        };

        if (comptime opts.cache) |cache| {
            cache_state.save(cache, js_value);
        }
    }

    fn _call(comptime T: type, local: *const Local, info: FunctionCallbackInfo, func: anytype, comptime opts: Opts) !js.Value {
        const F = @TypeOf(func);
        var args: ParameterTypes(F) = undefined;
        if (comptime opts.static) {
            args = try getArgs(F, 0, local, info);
        } else if (comptime opts.embedded_receiver) {
            args = try getArgs(F, 1, local, info);
            @field(args, "0") = @ptrCast(@alignCast(info.getData() orelse unreachable));
        } else {
            args = try getArgs(F, 1, local, info);
            @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
        }
        const res = @call(.auto, func, args);
        const js_value = try local.zigValueToJs(res, .{
            .as_typed_array = opts.as_typed_array,
            .null_as_undefined = opts.null_as_undefined,
        });
        info.getReturnValue().set(js_value);
        return js_value;
    }

    // We can cache a value directly into the v8::Object so that our callback to fetch a property
    // can be fast. Generally, think of it like this:
    //   fn callback(handle: *const v8.FunctionCallbackInfo) callconv(.c) void {
    //       const js_obj = info.getThis();
    //       const cached_value = js_obj.getFromCache("Nodes.childNodes");
    //       info.returnValue().set(cached_value);
    //   }
    //
    // That above pseudocode snippet is largely what this respondFromCache is doing.
    // But on miss, it's also setting the `cache_state` with all of the data it
    // got checking the cache, so that, once we get the value from our Zig code,
    // it's quick to store in the v8::Object for subsequent calls.
    fn respondFromCache(comptime cache: Opts.Caching, ctx: *Context, v8_context: *const v8.Context, info: FunctionCallbackInfo, cache_state: *CacheState) bool {
        const js_this = info.getThis();
        const return_value = info.getReturnValue();

        switch (cache) {
            .internal => |idx| {
                // Defensive check: verify object has enough internal fields.
                // This guards against edge cases where signature check passes but
                // the receiver doesn't have expected internal fields (e.g., global
                // proxy vs global object, cross-context scenarios).
                if (v8.v8__Object__InternalFieldCount(js_this) <= idx) {
                    if (comptime IS_DEBUG) {
                        std.debug.assert(false);
                    }
                    return false;
                }

                if (v8.v8__Object__GetInternalField(js_this, idx)) |cached| {
                    // means we can't cache undefined, since we can't tell the
                    // difference between "it isn't in the cache" and  "it's
                    // in the cache with a value of undefined"
                    if (!v8.v8__Value__IsUndefined(cached)) {
                        return_value.set(cached);
                        return true;
                    }
                }

                // store this so that we can quickly save the result into the cache
                cache_state.* = .{
                    .js_this = js_this,
                    .v8_context = v8_context,
                    .mode = .{ .internal = idx },
                };
            },
            .private => |private_symbol| {
                const global_handle = &@field(ctx.env.private_symbols, private_symbol).handle;
                const private_key: *const v8.Private = v8.v8__Global__Get(global_handle, ctx.isolate.handle).?;
                if (v8.v8__Object__GetPrivate(js_this, v8_context, private_key)) |cached| {
                    // This means we can't cache "undefined", since we can't tell
                    // the difference between a (a) undefined == not in the cache
                    // and (b) undefined == the cache value.  If this becomes
                    // important, we can check HasPrivate first. But that requires
                    // calling HasPrivate then GetPrivate.
                    if (!v8.v8__Value__IsUndefined(cached)) {
                        return_value.set(cached);
                        return true;
                    }
                }

                // store this so that we can quickly save the result into the cache
                cache_state.* = .{
                    .js_this = js_this,
                    .v8_context = v8_context,
                    .mode = .{ .private = private_key },
                };
            },
        }

        // cache miss
        return false;
    }

    const CacheState = struct {
        js_this: *const v8.Object,
        v8_context: *const v8.Context,
        mode: union(enum) {
            internal: u8,
            private: *const v8.Private,
        },

        pub fn save(self: *const CacheState, comptime cache: Opts.Caching, js_value: js.Value) void {
            if (comptime cache == .internal) {
                v8.v8__Object__SetInternalField(self.js_this, self.mode.internal, js_value.handle);
            } else {
                var out: v8.MaybeBool = undefined;
                v8.v8__Object__SetPrivate(self.js_this, self.v8_context, self.mode.private, js_value.handle, &out);
            }
        }
    };
};

// If we call a method in javascript: cat.lives('nine');
//
// Then we'd expect a Zig function with 2 parameters: a self and the string.
// In this case, offset == 1. Offset is always 1 for setters or methods.
//
// Offset is always 0 for constructors.
//
// For constructors, setters and methods, we can further increase offset + 1
// if the first parameter is an instance of Page.
//
// Finally, if the JS function is called with _more_ parameters and
// the last parameter in Zig is an array, we'll try to slurp the additional
// parameters into the array.
fn getArgs(comptime F: type, comptime offset: usize, local: *const Local, info: FunctionCallbackInfo) !ParameterTypes(F) {
    var args: ParameterTypes(F) = undefined;

    const params = @typeInfo(F).@"fn".params[offset..];
    // Except for the constructor, the first parameter is always `self`
    // This isn't something we'll bind from JS, so skip it.
    const params_to_map = blk: {
        if (params.len == 0) {
            return args;
        }

        // If the last parameter is Frame/Page/Session/Execution, set it from
        // context and exclude it from our params slice, because we don't want
        // to bind it to a JS argument.
        const LastParamType = params[params.len - 1].type.?;
        if (comptime isFrame(LastParamType) or isPage(LastParamType) or isExecution(LastParamType) or isSession(LastParamType)) {
            @field(args, tupleFieldName(params.len - 1 + offset)) = getGlobalArg(LastParamType, local.ctx);
            break :blk params[0 .. params.len - 1];
        }

        // we have neither a Frame/Page/Session/Execution nor a JsObject.
        // All params must be bound to a JavaScript value.
        break :blk params;
    };

    if (params_to_map.len == 0) {
        return args;
    }

    const js_parameter_count = info.length();
    const last_js_parameter = params_to_map.len - 1;
    var is_variadic = false;

    {
        // This is going to get complicated. If the last Zig parameter
        // is a slice AND the corresponding javascript parameter is
        // NOT an an array, then we'll treat it as a variadic.

        const last_parameter_type = params_to_map[params_to_map.len - 1].type.?;
        const last_parameter_type_info = @typeInfo(last_parameter_type);
        if (last_parameter_type_info == .pointer and last_parameter_type_info.pointer.size == .slice) {
            const slice_type = last_parameter_type_info.pointer.child;
            const corresponding_js_value = info.getArg(@intCast(last_js_parameter), local);
            if (slice_type == js.Value or (corresponding_js_value.isArray() == false and corresponding_js_value.isTypedArray() == false and slice_type != u8)) {
                is_variadic = true;
                if (js_parameter_count == 0) {
                    @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
                } else if (js_parameter_count >= params_to_map.len) {
                    const arr = try local.call_arena.alloc(last_parameter_type_info.pointer.child, js_parameter_count - params_to_map.len + 1);
                    for (arr, last_js_parameter..) |*a, i| {
                        a.* = try local.jsValueToZig(slice_type, info.getArg(@intCast(i), local));
                    }
                    @field(args, tupleFieldName(params_to_map.len + offset - 1)) = arr;
                } else {
                    @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
                }
            }
        }
    }

    inline for (params_to_map, 0..) |param, i| {
        const field_index = comptime i + offset;
        if (comptime i == params_to_map.len - 1) {
            if (is_variadic) {
                break;
            }
        }

        if (comptime isFrame(param.type.?)) {
            @compileError("Frame must be the last parameter: " ++ @typeName(F));
        } else if (comptime isPage(param.type.?)) {
            @compileError("Page must be the last parameter: " ++ @typeName(F));
        } else if (comptime isExecution(param.type.?)) {
            @compileError("Execution must be the last parameter: " ++ @typeName(F));
        } else if (comptime isSession(param.type.?)) {
            @compileError("Session must be the last parameter: " ++ @typeName(F));
        } else if (i >= js_parameter_count) {
            if (@typeInfo(param.type.?) != .optional) {
                return error.InvalidArgument;
            }
            @field(args, tupleFieldName(field_index)) = null;
        } else {
            const js_val = info.getArg(@intCast(i), local);
            // Only fold errors we don't recognize into InvalidArgument; let
            // domain-meaningful ones (e.g. InvalidCharacterError from a
            // String.OneByte param) propagate so handleError can map them
            // to the right DOMException. Compared by name because the per-
            // type instantiation of jsValueToZig may not include such errors
            // in its inferred error set.
            @field(args, tupleFieldName(field_index)) = local.jsValueToZig(param.type.?, js_val) catch |err| {
                if (err == error.JsException) {
                    // an exception thrown by user code (e.g. a toString
                    // getter) is pending; propagate it untouched
                    return err;
                }
                const DOMException = @import("../webapi/DOMException.zig");
                if (DOMException.fromError(err) != null) {
                    return err;
                }
                return error.InvalidArgument;
            };
        }
    }

    return args;
}

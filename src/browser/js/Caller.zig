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
const log = @import("../../log.zig");
const string = @import("../../string.zig");

const Page = @import("../Page.zig");

const js = @import("js.zig");
const Local = @import("Local.zig");
const Context = @import("Context.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const ArenaAllocator = std.heap.ArenaAllocator;

const CALL_ARENA_RETAIN = 1024 * 16;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Caller = @This();
local: Local,
prev_local: ?*const js.Local,
prev_context: *Context,

// Takes the raw v8 isolate and extracts the context from it.
pub fn init(self: *Caller, v8_isolate: *v8.Isolate) void {
    const v8_context = v8.v8__Isolate__GetCurrentContext(v8_isolate).?;
    initWithContext(self, Context.fromC(v8_context), v8_context);
}

fn initWithContext(self: *Caller, ctx: *Context, v8_context: *const v8.Context) void {
    ctx.call_depth += 1;
    self.* = Caller{
        .local = .{
            .ctx = ctx,
            .handle = v8_context,
            .call_arena = ctx.call_arena,
            .isolate = ctx.isolate,
        },
        .prev_local = ctx.local,
        .prev_context = ctx.page.js,
    };
    ctx.page.js = ctx;
    ctx.local = &self.local;
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

    ctx.call_depth = call_depth;
    ctx.local = self.prev_local;
    ctx.page.js = self.prev_context;
}

pub const CallOpts = struct {
    dom_exception: bool = false,
    null_as_undefined: bool = false,
    as_typed_array: bool = false,
};

pub fn constructor(self: *Caller, comptime T: type, func: anytype, handle: *const v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = FunctionCallbackInfo{ .handle = handle };

    if (!info.isConstructCall()) {
        handleError(T, @TypeOf(func), local, error.InvalidArgument, info, opts);
        return;
    }

    self._constructor(func, info) catch |err| {
        handleError(T, @TypeOf(func), local, err, info, opts);
    };
}

fn _constructor(self: *Caller, func: anytype, info: FunctionCallbackInfo) !void {
    const F = @TypeOf(func);
    const local = &self.local;
    const args = try getArgs(F, 0, local, info);
    const res = @call(.auto, func, args);

    const ReturnType = @typeInfo(F).@"fn".return_type orelse {
        @compileError(@typeName(F) ++ " has a constructor without a return type");
    };

    const new_this_handle = info.getThis();
    var this = js.Object{ .local = local, .handle = new_this_handle };
    if (@typeInfo(ReturnType) == .error_union) {
        const non_error_res = res catch |err| return err;
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

pub fn getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getIndex(T, local, func, idx, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info, opts);
        // not intercepted
        return 0;
    };
}

fn _getIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = local.ctx.page;
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getNamedIndex(T, local, func, name, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info, opts);
        // not intercepted
        return 0;
    };
}

fn _getNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = local.ctx.page;
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, js_value: *const v8.Value, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _setNamedIndex(T, local, func, name, .{ .local = &self.local, .handle = js_value }, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info, opts);
        // not intercepted
        return 0;
    };
}

fn _setNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, js_value: js.Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    @field(args, "2") = try local.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = local.ctx.page;
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, false, local, ret, info, opts);
}

pub fn deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _deleteNamedIndex(T, local, func, name, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info, opts);
        return 0;
    };
}

fn _deleteNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = local.ctx.page;
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, false, local, ret, info, opts);
}

fn handleIndexedReturn(comptime T: type, comptime F: type, comptime getter: bool, local: *const Local, ret: anytype, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
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
                        // not intercepted
                        return 0;
                    }
                }
                handleError(T, F, local, err, info, opts);
                // not intercepted
                return 0;
            };
        },
        else => ret,
    };

    if (comptime getter) {
        info.getReturnValue().set(try local.zigValueToJs(non_error_ret, opts));
    }
    // intercepted
    return 1;
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

fn handleError(comptime T: type, comptime F: type, local: *const Local, err: anyerror, info: anytype, comptime opts: CallOpts) void {
    const isolate = local.isolate;

    if (comptime @import("builtin").mode == .Debug and @TypeOf(info) == FunctionCallbackInfo) {
        if (log.enabled(.js, .warn)) {
            logFunctionCallError(local, @typeName(T), @typeName(F), err, info);
        }
    }

    const js_err: *const v8.Value = switch (err) {
        error.TryCatchRethrow => return,
        error.InvalidArgument => isolate.createTypeError("invalid argument"),
        error.TypeError => isolate.createTypeError(""),
        error.OutOfMemory => isolate.createError("out of memory"),
        error.IllegalConstructor => isolate.createError("Illegal Contructor"),
        else => blk: {
            if (comptime opts.dom_exception) {
                const DOMException = @import("../webapi/DOMException.zig");
                if (DOMException.fromError(err)) |ex| {
                    const value = local.zigValueToJs(ex, .{}) catch break :blk isolate.createError("internal error");
                    break :blk value.handle;
                }
            }
            break :blk isolate.createError(@errorName(err));
        },
    };

    const js_exception = isolate.throwException(js_err);
    info.getReturnValue().setValueHandle(js_exception);
}

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(local: *const Local, type_name: []const u8, func: []const u8, err: anyerror, info: FunctionCallbackInfo) void {
    const args_dump = serializeFunctionArgs(local, info) catch "failed to serialize args";
    log.info(.js, "function call error", .{
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

fn isPage(comptime T: type) bool {
    return T == *Page or T == *const Page;
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
        static: bool = false,
        dom_exception: bool = false,
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        cache: ?Caching = null,

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
        const v8_context = v8.v8__Isolate__GetCurrentContext(v8_isolate).?;

        const ctx = Context.fromC(v8_context);
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

        const js_value = _call(T, &caller.local, info, func, opts) catch |err| {
            handleError(T, @TypeOf(func), &caller.local, err, info, .{
                .dom_exception = opts.dom_exception,
                .as_typed_array = opts.as_typed_array,
                .null_as_undefined = opts.null_as_undefined,
            });
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
        } else {
            args = try getArgs(F, 1, local, info);
            @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
        }
        const res = @call(.auto, func, args);
        const js_value = try local.zigValueToJs(res, .{
            .dom_exception = opts.dom_exception,
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
                if (v8.v8__Object__GetInternalField(js_this, idx)) |cached| {
                    // means we can't cache undefined, since we can't tell the
                    // difference between "it isn't in the cache" and  "it's
                    // in the cache with a valud of undefined"
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

        // If the last parameter is the Page, set it, and exclude it
        // from our params slice, because we don't want to bind it to
        // a JS argument
        if (comptime isPage(params[params.len - 1].type.?)) {
            @field(args, tupleFieldName(params.len - 1 + offset)) = local.ctx.page;
            break :blk params[0 .. params.len - 1];
        }

        // we have neither a Page nor a JsObject. All params must be
        // bound to a JavaScript value.
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
            if (corresponding_js_value.isArray() == false and corresponding_js_value.isTypedArray() == false and slice_type != u8) {
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

        if (comptime isPage(param.type.?)) {
            @compileError("Page must be the last parameter (or 2nd last if there's a JsThis): " ++ @typeName(F));
        } else if (i >= js_parameter_count) {
            if (@typeInfo(param.type.?) != .optional) {
                return error.InvalidArgument;
            }
            @field(args, tupleFieldName(field_index)) = null;
        } else {
            const js_val = info.getArg(@intCast(i), local);
            @field(args, tupleFieldName(field_index)) = local.jsValueToZig(param.type.?, js_val) catch {
                return error.InvalidArgument;
            };
        }
    }

    return args;
}

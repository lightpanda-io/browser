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
const Page = @import("../Page.zig");

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Context = @import("Context.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const CALL_ARENA_RETAIN = 1024 * 16;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Caller = @This();
local: js.Local,
prev_local: ?*const js.Local,

// Takes the raw v8 isolate and extracts the context from it.
pub fn init(self: *Caller, v8_isolate: *v8.Isolate) void {
    const v8_context_handle = v8.v8__Isolate__GetCurrentContext(v8_isolate);

    const embedder_data = v8.v8__Context__GetEmbedderData(v8_context_handle, 1);
    var lossless: bool = undefined;
    const ctx: *Context = @ptrFromInt(v8.v8__BigInt__Uint64Value(embedder_data, &lossless));

    ctx.call_depth += 1;
    self.* = Caller{
        .local = .{
            .ctx = ctx,
            .handle = v8_context_handle.?,
            .call_arena = ctx.call_arena,
            .isolate = .{ .handle = v8_isolate },
        },
        .prev_local = ctx.local,
    };
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
}

pub const CallOpts = struct {
    dom_exception: bool = false,
    null_as_undefined: bool = false,
    as_typed_array: bool = false,
};

pub fn constructor(self: *Caller, comptime T: type, func: anytype, handle: *const v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = FunctionCallbackInfo{ .handle = handle };

    if (!info.isConstructCall()) {
        self.handleError(T, @TypeOf(func), error.InvalidArgument, info, opts);
        return;
    }

    self._constructor(func, info) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
    };
}

fn _constructor(self: *Caller, func: anytype, info: FunctionCallbackInfo) !void {
    const F = @TypeOf(func);
    const args = try self.getArgs(F, 0, info);
    const res = @call(.auto, func, args);

    const ReturnType = @typeInfo(F).@"fn".return_type orelse {
        @compileError(@typeName(F) ++ " has a constructor without a return type");
    };

    const new_this_handle = info.getThis();
    var this = js.Object{ .local = &self.local, .handle = new_this_handle };
    if (@typeInfo(ReturnType) == .error_union) {
        const non_error_res = res catch |err| return err;
        this = try self.local.mapZigInstanceToJs(new_this_handle, non_error_res);
    } else {
        this = try self.local.mapZigInstanceToJs(new_this_handle, res);
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

pub fn method(self: *Caller, comptime T: type, func: anytype, handle: *const v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = FunctionCallbackInfo{ .handle = handle };
    self._method(T, func, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
    };
}

fn _method(self: *Caller, comptime T: type, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) !void {
    const F = @TypeOf(func);
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.local.isolate);
    defer handle_scope.deinit();

    var args = try self.getArgs(F, 1, info);
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    const res = @call(.auto, func, args);
    info.getReturnValue().set(try self.local.zigValueToJs(res, opts));
}

pub fn function(self: *Caller, comptime T: type, func: anytype, handle: *const v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = FunctionCallbackInfo{ .handle = handle };
    self._function(func, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
    };
}

fn _function(self: *Caller, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) !void {
    const F = @TypeOf(func);
    const args = try self.getArgs(F, 0, info);
    const res = @call(.auto, func, args);
    info.getReturnValue().set(try self.local.zigValueToJs(res, opts));
}

pub fn getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return self._getIndex(T, func, idx, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        // not intercepted
        return 0;
    };
}

fn _getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args = try self.getArgs(F, 2, info);
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, true, ret, info, opts);
}

pub fn getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return self._getNamedIndex(T, func, name, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        // not intercepted
        return 0;
    };
}

fn _getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args = try self.getArgs(F, 2, info);
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try self.nameToString(name);
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, true, ret, info, opts);
}

pub fn setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, js_value: *const v8.Value, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return self._setNamedIndex(T, func, name, .{ .local = &self.local, .handle = js_value }, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        // not intercepted
        return 0;
    };
}

fn _setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, js_value: js.Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try self.nameToString(name);
    @field(args, "2") = try self.local.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = self.local.ctx.page;
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, false, ret, info, opts);
}

pub fn deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    var hs: js.HandleScope = undefined;
    hs.init(self.local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return self._deleteNamedIndex(T, func, name, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        return 0;
    };
}

fn _deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try self.nameToString(name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = self.local.ctx.page;
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, false, ret, info, opts);
}

fn handleIndexedReturn(self: *Caller, comptime T: type, comptime F: type, comptime getter: bool, ret: anytype, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
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
                self.handleError(T, F, err, info, opts);
                // not intercepted
                return 0;
            };
        },
        else => ret,
    };

    if (comptime getter) {
        info.getReturnValue().set(try self.local.zigValueToJs(non_error_ret, opts));
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

fn nameToString(self: *const Caller, name: *const v8.Name) ![]const u8 {
    return self.local.valueHandleToString(@ptrCast(name), .{});
}

fn handleError(self: *Caller, comptime T: type, comptime F: type, err: anyerror, info: anytype, comptime opts: CallOpts) void {
    const isolate = self.local.isolate;

    if (comptime @import("builtin").mode == .Debug and @TypeOf(info) == FunctionCallbackInfo) {
        if (log.enabled(.js, .warn)) {
            self.logFunctionCallError(@typeName(T), @typeName(F), err, info);
        }
    }

    const js_err: *const v8.Value = switch (err) {
        error.InvalidArgument => isolate.createTypeError("invalid argument"),
        error.OutOfMemory => isolate.createError("out of memory"),
        error.IllegalConstructor => isolate.createError("Illegal Contructor"),
        else => blk: {
            if (comptime opts.dom_exception) {
                const DOMException = @import("../webapi/DOMException.zig");
                if (DOMException.fromError(err)) |ex| {
                    const value = self.local.zigValueToJs(ex, .{}) catch break :blk isolate.createError("internal error");
                    break :blk value.handle;
                }
            }
            break :blk isolate.createError(@errorName(err));
        },
    };

    const js_exception = isolate.throwException(js_err);
    info.getReturnValue().setValueHandle(js_exception);
}

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
fn getArgs(self: *const Caller, comptime F: type, comptime offset: usize, info: anytype) !ParameterTypes(F) {
    const local = &self.local;
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

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(self: *Caller, type_name: []const u8, func: []const u8, err: anyerror, info: FunctionCallbackInfo) void {
    const args_dump = self.serializeFunctionArgs(info) catch "failed to serialize args";
    log.info(.js, "function call error", .{
        .type = type_name,
        .func = func,
        .err = err,
        .args = args_dump,
        .stack = self.local.stackTrace() catch |err1| @errorName(err1),
    });
}

fn serializeFunctionArgs(self: *Caller, info: FunctionCallbackInfo) ![]const u8 {
    const local = &self.local;
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

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

const log = @import("../../log.zig");

const js = @import("js.zig");
const v8 = js.v8;

const Context = @import("Context.zig");

const Page = @import("../Page.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const CALL_ARENA_RETAIN = 1024 * 16;

// Responsible for calling Zig functions from JS invocations. This could
// probably just contained in ExecutionWorld, but having this specific logic, which
// is somewhat repetitive between constructors, functions, getters, etc contained
// here does feel like it makes it cleaner.
const Caller = @This();
context: *Context,
v8_context: v8.Context,
isolate: v8.Isolate,
call_arena: Allocator,

// info is a v8.PropertyCallbackInfo or a v8.FunctionCallback
// All we really want from it is the isolate.
// executor = Isolate -> getCurrentContext -> getEmbedderData()
pub fn init(info: anytype) Caller {
    const isolate = info.getIsolate();
    const v8_context = isolate.getCurrentContext();
    const context: *Context = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

    context.call_depth += 1;
    return .{
        .context = context,
        .isolate = isolate,
        .v8_context = v8_context,
        .call_arena = context.call_arena,
    };
}

pub fn deinit(self: *Caller) void {
    const context = self.context;
    const call_depth = context.call_depth - 1;

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
        const arena: *ArenaAllocator = @ptrCast(@alignCast(context.call_arena.ptr));
        _ = arena.reset(.{ .retain_with_limit = CALL_ARENA_RETAIN });
    }

    context.call_depth = call_depth;
}

pub const CallOpts = struct {
    dom_exception: bool = false,
    null_as_undefined: bool = false,
    as_typed_array: bool = false,
};

pub fn constructor(self: *Caller, comptime T: type, func: anytype, info: v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    self._constructor(func, info) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
    };
}
pub fn _constructor(self: *Caller, func: anytype, info: v8.FunctionCallbackInfo) !void {
    const F = @TypeOf(func);
    const args = try self.getArgs(F, 0, info);
    const res = @call(.auto, func, args);

    const ReturnType = @typeInfo(F).@"fn".return_type orelse {
        @compileError(@typeName(F) ++ " has a constructor without a return type");
    };

    const new_this = info.getThis();
    var this = new_this;
    if (@typeInfo(ReturnType) == .error_union) {
        const non_error_res = res catch |err| return err;
        this = (try self.context.mapZigInstanceToJs(this, non_error_res)).castToObject();
    } else {
        this = (try self.context.mapZigInstanceToJs(this, res)).castToObject();
    }

    // If we got back a different object (existing wrapper), copy the prototype
    // from new object. (this happens when we're upgrading an CustomElement)
    if (this.handle != new_this.handle) {
        const new_prototype = new_this.getPrototype();
        _ = this.setPrototype(self.context.v8_context, new_prototype.castTo(v8.Object));
    }

    info.getReturnValue().set(this);
}

pub fn method(self: *Caller, comptime T: type, func: anytype, info: v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    self._method(T, func, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
    };
}

pub fn _method(self: *Caller, comptime T: type, func: anytype, info: v8.FunctionCallbackInfo, comptime opts: CallOpts) !void {
    const F = @TypeOf(func);
    var handle_scope: v8.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();

    var args = try self.getArgs(F, 1, info);
    @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
    const res = @call(.auto, func, args);
    info.getReturnValue().set(try self.context.zigValueToJs(res, opts));
}

pub fn function(self: *Caller, comptime T: type, func: anytype, info: v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    self._function(func, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
    };
}

pub fn _function(self: *Caller, func: anytype, info: v8.FunctionCallbackInfo, comptime opts: CallOpts) !void {
    const F = @TypeOf(func);
    const context = self.context;
    const args = try self.getArgs(F, 0, info);
    const res = @call(.auto, func, args);
    info.getReturnValue().set(try context.zigValueToJs(res, opts));
}

pub fn getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    return self._getIndex(T, func, idx, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        return v8.Intercepted.No;
    };
}

pub fn _getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args = try self.getArgs(F, 2, info);
    @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
    @field(args, "1") = idx;
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, true, ret, info, opts);
}

pub fn getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: v8.Name, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    return self._getNamedIndex(T, func, name, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        return v8.Intercepted.No;
    };
}

pub fn _getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: v8.Name, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args = try self.getArgs(F, 2, info);
    @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
    @field(args, "1") = try self.nameToString(name);
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, true, ret, info, opts);
}

pub fn setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: v8.Name, js_value: v8.Value, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    return self._setNamedIndex(T, func, name, js_value, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        return v8.Intercepted.No;
    };
}

pub fn _setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: v8.Name, js_value: v8.Value, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
    @field(args, "1") = try self.nameToString(name);
    @field(args, "2") = try self.context.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = self.context.page;
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, false, ret, info, opts);
}

pub fn deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: v8.Name, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) u8 {
    return self._deleteNamedIndex(T, func, name, info, opts) catch |err| {
        self.handleError(T, @TypeOf(func), err, info, opts);
        return v8.Intercepted.No;
    };
}

pub fn _deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: v8.Name, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
    @field(args, "1") = try self.nameToString(name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = self.context.page;
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, false, ret, info, opts);
}

fn handleIndexedReturn(self: *Caller, comptime T: type, comptime F: type, comptime getter: bool, ret: anytype, info: v8.PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
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
                        return v8.Intercepted.No;
                    }
                }
                self.handleError(T, F, err, info, opts);
                return v8.Intercepted.No;
            };
        },
        else => ret,
    };

    if (comptime getter) {
        info.getReturnValue().set(try self.context.zigValueToJs(non_error_ret, opts));
    }
    return v8.Intercepted.Yes;
}

fn isInErrorSet(err: anyerror, comptime T: type) bool {
    inline for (@typeInfo(T).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

fn namedSetOrDeleteCall(res: anytype, has_value: bool) !u8 {
    if (@typeInfo(@TypeOf(res)) == .error_union) {
        _ = try res;
    }
    if (has_value == false) {
        return v8.Intercepted.No;
    }
    return v8.Intercepted.Yes;
}

fn nameToString(self: *Caller, name: v8.Name) ![]const u8 {
    return self.context.valueToString(.{ .handle = name.handle }, .{});
}

fn isSelfReceiver(comptime T: type, comptime F: type) bool {
    return checkSelfReceiver(T, F, false);
}
fn assertSelfReceiver(comptime T: type, comptime F: type) void {
    _ = checkSelfReceiver(T, F, true);
}
fn checkSelfReceiver(comptime T: type, comptime F: type, comptime fail: bool) bool {
    const params = @typeInfo(F).@"fn".params;
    if (params.len == 0) {
        if (fail) {
            @compileError(@typeName(F) ++ " must have a self parameter");
        }
        return false;
    }

    const first_param = params[0].type.?;
    if (first_param != *T and first_param != *const T) {
        if (fail) {
            @compileError(std.fmt.comptimePrint("The first parameter to {s} must be a *{s} or *const {s}. Got: {s}", .{
                @typeName(F),
                @typeName(T),
                @typeName(T),
                @typeName(first_param),
            }));
        }
        return false;
    }
    return true;
}

fn assertIsPageArg(comptime T: type, comptime F: type, index: comptime_int) void {
    const param = @typeInfo(F).@"fn".params[index].type.?;
    if (isPage(param)) {
        return;
    }
    @compileError(std.fmt.comptimePrint("The {d} parameter of {s}.{s} must be a *Page or *const Page. Got: {s}", .{ index, @typeName(T), @typeName(F), @typeName(param) }));
}

fn handleError(self: *Caller, comptime T: type, comptime F: type, err: anyerror, info: anytype, comptime opts: CallOpts) void {
    const isolate = self.isolate;

    if (comptime @import("builtin").mode == .Debug and @hasDecl(@TypeOf(info), "length")) {
        if (log.enabled(.js, .warn)) {
            self.logFunctionCallError(@typeName(T), @typeName(F), err, info);
        }
    }

    var js_err: ?v8.Value = switch (err) {
        error.InvalidArgument => createTypeException(isolate, "invalid argument"),
        error.OutOfMemory => js._createException(isolate, "out of memory"),
        error.IllegalConstructor => js._createException(isolate, "Illegal Contructor"),
        else => blk: {
            if (!comptime opts.dom_exception) {
                break :blk null;
            }
            const DOMException = @import("../webapi/DOMException.zig");
            const ex = DOMException.fromError(err) orelse break :blk null;
            break :blk self.context.zigValueToJs(ex, .{}) catch js._createException(isolate, "internal error");
        },
    };

    if (js_err == null) {
        js_err = js._createException(isolate, @errorName(err));
    }
    const js_exception = isolate.throwException(js_err.?);
    info.getReturnValue().setValueHandle(js_exception.handle);
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
    const context = self.context;
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
            @field(args, tupleFieldName(params.len - 1 + offset)) = self.context.page;
            break :blk params[0 .. params.len - 1];
        }

        // If the last parameter is a special JsThis, set it, and exclude it
        // from our params slice, because we don't want to bind it to
        // a JS argument
        if (comptime params[params.len - 1].type.? == js.This) {
            @field(args, tupleFieldName(params.len - 1 + offset)) = .{ .obj = .{
                .context = context,
                .js_obj = info.getThis(),
            } };

            // AND the 2nd last parameter is state
            if (params.len > 1 and comptime isPage(params[params.len - 2].type.?)) {
                @field(args, tupleFieldName(params.len - 2 + offset)) = self.context.page;
                break :blk params[0 .. params.len - 2];
            }

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
            const corresponding_js_value = info.getArg(@as(u32, @intCast(last_js_parameter)));
            if (corresponding_js_value.isArray() == false and corresponding_js_value.isTypedArray() == false and slice_type != u8) {
                is_variadic = true;
                if (js_parameter_count == 0) {
                    @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
                } else if (js_parameter_count >= params_to_map.len) {
                    const arr = try self.call_arena.alloc(last_parameter_type_info.pointer.child, js_parameter_count - params_to_map.len + 1);
                    for (arr, last_js_parameter..) |*a, i| {
                        const js_value = info.getArg(@as(u32, @intCast(i)));
                        a.* = try context.jsValueToZig(slice_type, js_value);
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
        } else if (comptime param.type.? == js.This) {
            @compileError("JsThis must be the last parameter: " ++ @typeName(F));
        } else if (i >= js_parameter_count) {
            if (@typeInfo(param.type.?) != .optional) {
                return error.InvalidArgument;
            }
            @field(args, tupleFieldName(field_index)) = null;
        } else {
            const js_value = info.getArg(@as(u32, @intCast(i)));
            @field(args, tupleFieldName(field_index)) = context.jsValueToZig(param.type.?, js_value) catch {
                return error.InvalidArgument;
            };
        }
    }

    return args;
}

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(self: *Caller, type_name: []const u8, func: []const u8, err: anyerror, info: v8.FunctionCallbackInfo) void {
    const args_dump = self.serializeFunctionArgs(info) catch "failed to serialize args";
    log.info(.js, "function call error", .{
        .type = type_name,
        .func = func,
        .err = err,
        .args = args_dump,
        .stack = self.context.stackTrace() catch |err1| @errorName(err1),
    });
}

fn serializeFunctionArgs(self: *Caller, info: v8.FunctionCallbackInfo) ![]const u8 {
    const context = self.context;
    var buf = std.Io.Writer.Allocating.init(context.call_arena);

    const separator = log.separator();
    for (0..info.length()) |i| {
        try buf.writer.print("{s}{d} - ", .{ separator, i + 1 });
        try context.debugValue(info.getArg(@intCast(i)), &buf.writer);
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

fn createTypeException(isolate: v8.Isolate, msg: []const u8) v8.Value {
    return v8.Exception.initTypeError(v8.String.initUtf8(isolate, msg));
}

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
const log = @import("../../log.zig");

const v8 = js.v8;

const Context = @import("Context.zig");
const Page = @import("../Page.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const CALL_ARENA_RETAIN = 1024 * 16;
const IS_DEBUG = @import("builtin").mode == .Debug;

// ============================================================================
// Internal Callback Info Wrappers
// ============================================================================
// These wrap the raw v8 C API to provide a cleaner interface.
// They are not exported - internal to this module only.

const Value = struct {
    handle: *const v8.Value,

    fn isArray(self: Value) bool {
        return v8.v8__Value__IsArray(self.handle);
    }

    fn isTypedArray(self: Value) bool {
        return v8.v8__Value__IsTypedArray(self.handle);
    }

    fn isFunction(self: Value) bool {
        return v8.v8__Value__IsFunction(self.handle);
    }
};

const Name = struct {
    handle: *const v8.Name,
};

const FunctionCallbackInfo = struct {
    handle: *const v8.FunctionCallbackInfo,

    fn length(self: FunctionCallbackInfo) u32 {
        return @intCast(v8.v8__FunctionCallbackInfo__Length(self.handle));
    }

    fn getArg(self: FunctionCallbackInfo, index: u32) Value {
        return .{ .handle = v8.v8__FunctionCallbackInfo__INDEX(self.handle, @intCast(index)).? };
    }

    fn getThis(self: FunctionCallbackInfo) *const v8.Object {
        return v8.v8__FunctionCallbackInfo__This(self.handle).?;
    }

    fn getReturnValue(self: FunctionCallbackInfo) ReturnValue {
        var rv: v8.ReturnValue = undefined;
        v8.v8__FunctionCallbackInfo__GetReturnValue(self.handle, &rv);
        return .{ .handle = rv };
    }

    fn isConstructCall(self: FunctionCallbackInfo) bool {
        return v8.v8__FunctionCallbackInfo__IsConstructCall(self.handle);
    }
};

const PropertyCallbackInfo = struct {
    handle: *const v8.PropertyCallbackInfo,

    fn getThis(self: PropertyCallbackInfo) *const v8.Object {
        return v8.v8__PropertyCallbackInfo__This(self.handle).?;
    }

    fn getReturnValue(self: PropertyCallbackInfo) ReturnValue {
        var rv: v8.ReturnValue = undefined;
        v8.v8__PropertyCallbackInfo__GetReturnValue(self.handle, &rv);
        return .{ .handle = rv };
    }
};

const ReturnValue = struct {
    handle: v8.ReturnValue,

    fn set(self: ReturnValue, value: anytype) void {
        const T = @TypeOf(value);
        if (T == Value) {
            self.setValueHandle(value.handle);
        } else if (T == *const v8.Object) {
            self.setValueHandle(@ptrCast(value));
        } else if (T == *const v8.Value) {
            self.setValueHandle(value);
        } else if (T == js.Value) {
            self.setValueHandle(value.handle);
        } else {
            @compileError("Unsupported type for ReturnValue.set: " ++ @typeName(T));
        }
    }

    fn setValueHandle(self: ReturnValue, handle: *const v8.Value) void {
        v8.v8__ReturnValue__Set(self.handle, handle);
    }
};

// ============================================================================
// Caller - Responsible for calling Zig functions from JS invocations
// ============================================================================

pub const Caller = struct {
    context: *Context,
    isolate: js.Isolate,
    call_arena: Allocator,

    // Takes the raw v8 isolate and extracts the context from it.
    pub fn init(v8_isolate: *v8.Isolate) Caller {
        const isolate = js.Isolate{ .handle = v8_isolate };
        const v8_context_handle = v8.v8__Isolate__GetCurrentContext(v8_isolate);
        const embedder_data = v8.v8__Context__GetEmbedderData(v8_context_handle, 1);
        var lossless: bool = undefined;
        const context: *Context = @ptrFromInt(v8.v8__BigInt__Uint64Value(embedder_data, &lossless));

        context.call_depth += 1;
        return .{
            .context = context,
            .isolate = isolate,
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

    pub fn constructor(self: *Caller, comptime T: type, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) void {
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
        var this = js.Object{ .ctx = self.context, .handle = new_this_handle };
        if (@typeInfo(ReturnType) == .error_union) {
            const non_error_res = res catch |err| return err;
            this = try self.context.mapZigInstanceToJs(new_this_handle, non_error_res);
        } else {
            this = try self.context.mapZigInstanceToJs(new_this_handle, res);
        }

        // If we got back a different object (existing wrapper), copy the prototype
        // from new object. (this happens when we're upgrading an CustomElement)
        if (this.handle != new_this_handle) {
            const prototype_handle = v8.v8__Object__GetPrototype(new_this_handle).?;
            var out: v8.MaybeBool = undefined;
            v8.v8__Object__SetPrototype(this.handle, self.context.handle, prototype_handle, &out);
            if (comptime IS_DEBUG) {
                std.debug.assert(out.has_value and out.value);
            }
        }

        info.getReturnValue().set(this.handle);
    }

    pub fn method(self: *Caller, comptime T: type, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) void {
        self._method(T, func, info, opts) catch |err| {
            self.handleError(T, @TypeOf(func), err, info, opts);
        };
    }

    fn _method(self: *Caller, comptime T: type, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) !void {
        const F = @TypeOf(func);
        var handle_scope: js.HandleScope = undefined;
        handle_scope.init(self.isolate);
        defer handle_scope.deinit();

        var args = try self.getArgs(F, 1, info);
        @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
        const res = @call(.auto, func, args);
        info.getReturnValue().set(try self.context.zigValueToJs(res, opts));
    }

    pub fn function(self: *Caller, comptime T: type, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) void {
        self._function(func, info, opts) catch |err| {
            self.handleError(T, @TypeOf(func), err, info, opts);
        };
    }

    fn _function(self: *Caller, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) !void {
        const F = @TypeOf(func);
        const context = self.context;
        const args = try self.getArgs(F, 0, info);
        const res = @call(.auto, func, args);
        info.getReturnValue().set(try context.zigValueToJs(res, opts));
    }

    pub fn getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) u8 {
        return self._getIndex(T, func, idx, info, opts) catch |err| {
            self.handleError(T, @TypeOf(func), err, info, opts);
            // not intercepted
            return 0;
        };
    }

    fn _getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
        const F = @TypeOf(func);
        var args = try self.getArgs(F, 2, info);
        @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
        @field(args, "1") = idx;
        const ret = @call(.auto, func, args);
        return self.handleIndexedReturn(T, F, true, ret, info, opts);
    }

    pub fn getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: Name, info: PropertyCallbackInfo, comptime opts: CallOpts) u8 {
        return self._getNamedIndex(T, func, name, info, opts) catch |err| {
            self.handleError(T, @TypeOf(func), err, info, opts);
            // not intercepted
            return 0;
        };
    }

    fn _getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
        const F = @TypeOf(func);
        var args = try self.getArgs(F, 2, info);
        @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
        @field(args, "1") = try self.nameToString(name);
        const ret = @call(.auto, func, args);
        return self.handleIndexedReturn(T, F, true, ret, info, opts);
    }

    pub fn setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: Name, js_value: Value, info: PropertyCallbackInfo, comptime opts: CallOpts) u8 {
        return self._setNamedIndex(T, func, name, js_value, info, opts) catch |err| {
            self.handleError(T, @TypeOf(func), err, info, opts);
            // not intercepted
            return 0;
        };
    }

    fn _setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: Name, js_value: Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
        const F = @TypeOf(func);
        var args: ParameterTypes(F) = undefined;
        @field(args, "0") = try Context.typeTaggedAnyOpaque(*T, info.getThis());
        @field(args, "1") = try self.nameToString(name);
        @field(args, "2") = try self.context.jsValueToZig(@TypeOf(@field(args, "2")), js.Value{ .ctx = self.context, .handle = js_value.handle });
        if (@typeInfo(F).@"fn".params.len == 4) {
            @field(args, "3") = self.context.page;
        }
        const ret = @call(.auto, func, args);
        return self.handleIndexedReturn(T, F, false, ret, info, opts);
    }

    pub fn deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: Name, info: PropertyCallbackInfo, comptime opts: CallOpts) u8 {
        return self._deleteNamedIndex(T, func, name, info, opts) catch |err| {
            self.handleError(T, @TypeOf(func), err, info, opts);
            return 0;
        };
    }

    fn _deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u8 {
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
            info.getReturnValue().set(try self.context.zigValueToJs(non_error_ret, opts));
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

    fn nameToString(self: *Caller, name: Name) ![]const u8 {
        return self.context.valueToString(js.Value{ .ctx = self.context, .handle = @ptrCast(name.handle) }, .{});
    }

    fn handleError(self: *Caller, comptime T: type, comptime F: type, err: anyerror, info: anytype, comptime opts: CallOpts) void {
        const isolate = self.isolate;

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
                        const value = self.context.zigValueToJs(ex, .{}) catch break :blk isolate.createError("internal error");
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
                            a.* = try context.jsValueToZig(slice_type, js.Value{ .ctx = context, .handle = js_value.handle });
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
                const js_value = info.getArg(@as(u32, @intCast(i)));
                @field(args, tupleFieldName(field_index)) = context.jsValueToZig(param.type.?, js.Value{ .ctx = context, .handle = js_value.handle }) catch {
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
            .stack = self.context.stackTrace() catch |err1| @errorName(err1),
        });
    }

    fn serializeFunctionArgs(self: *Caller, info: FunctionCallbackInfo) ![]const u8 {
        const context = self.context;
        var buf = std.Io.Writer.Allocating.init(context.call_arena);

        const separator = log.separator();
        for (0..info.length()) |i| {
            try buf.writer.print("{s}{d} - ", .{ separator, i + 1 });
            const val = info.getArg(@intCast(i));
            try context.debugValue(js.Value{ .ctx = context, .handle = val.handle }, &buf.writer);
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
};

// ============================================================================
// Bridge Builder Functions
// ============================================================================

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;
        pub const ClassId = u16;

        pub fn constructor(comptime func: anytype, comptime opts: Constructor.Opts) Constructor {
            return Constructor.init(T, func, opts);
        }

        pub fn accessor(comptime getter: anytype, comptime setter: anytype, comptime opts: Accessor.Opts) Accessor {
            return Accessor.init(T, getter, setter, opts);
        }

        pub fn function(comptime func: anytype, comptime opts: Function.Opts) Function {
            return Function.init(T, func, opts);
        }

        pub fn indexed(comptime getter_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, opts);
        }

        pub fn namedIndexed(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, comptime opts: NamedIndexed.Opts) NamedIndexed {
            return NamedIndexed.init(T, getter_func, setter_func, deleter_func, opts);
        }

        pub fn iterator(comptime func: anytype, comptime opts: Iterator.Opts) Iterator {
            return Iterator.init(T, func, opts);
        }

        pub fn callable(comptime func: anytype, comptime opts: Callable.Opts) Callable {
            return Callable.init(T, func, opts);
        }

        pub fn property(value: anytype) Property {
            switch (@typeInfo(@TypeOf(value))) {
                .comptime_int, .int => return .{ .int = value },
                else => {},
            }
            @compileError("Property for " ++ @typeName(@TypeOf(value)) ++ " hasn't been defined yet");
        }

        pub fn prototypeChain() [prototypeChainLength(T)]js.PrototypeChainEntry {
            var entries: [prototypeChainLength(T)]js.PrototypeChainEntry = undefined;

            entries[0] = .{ .offset = 0, .index = JsApiLookup.getId(T.JsApi) };

            if (entries.len == 1) {
                return entries;
            }

            var Prototype = T;
            inline for (entries[1..]) |*entry| {
                const Next = PrototypeType(Prototype).?;
                entry.* = .{
                    .index = JsApiLookup.getId(Next.JsApi),
                    .offset = @offsetOf(Prototype, "_proto"),
                };
                Prototype = Next;
            }
            return entries;
        }
    };
}

pub const Constructor = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        dom_exception: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{ .func = struct {
            fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                var caller = Caller.init(v8_isolate);
                defer caller.deinit();

                const info = FunctionCallbackInfo{ .handle = handle.? };
                caller.constructor(T, func, info, .{
                    .dom_exception = opts.dom_exception,
                });
            }
        }.wrap };
    }
};

pub const Function = struct {
    static: bool,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        static: bool = false,
        dom_exception: bool = false,
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Function {
        return .{
            .static = opts.static,
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller = Caller.init(v8_isolate);
                    defer caller.deinit();

                    const info = FunctionCallbackInfo{ .handle = handle.? };
                    if (comptime opts.static) {
                        caller.function(T, func, info, .{
                            .dom_exception = opts.dom_exception,
                            .as_typed_array = opts.as_typed_array,
                            .null_as_undefined = opts.null_as_undefined,
                        });
                    } else {
                        caller.method(T, func, info, .{
                            .dom_exception = opts.dom_exception,
                            .as_typed_array = opts.as_typed_array,
                            .null_as_undefined = opts.null_as_undefined,
                        });
                    }
                }
            }.wrap,
        };
    }
};

pub const Accessor = struct {
    static: bool = false,
    getter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,
    setter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,

    const Opts = struct {
        static: bool = false,
        cache: ?[]const u8 = null, // @ZIGDOM
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime setter: anytype, comptime opts: Opts) Accessor {
        var accessor = Accessor{
            .static = opts.static,
        };

        if (@typeInfo(@TypeOf(getter)) != .null) {
            accessor.getter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller = Caller.init(v8_isolate);
                    defer caller.deinit();

                    const info = FunctionCallbackInfo{ .handle = handle.? };
                    caller.method(T, getter, info, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            accessor.setter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller = Caller.init(v8_isolate);
                    defer caller.deinit();

                    const info = FunctionCallbackInfo{ .handle = handle.? };
                    std.debug.assert(info.length() == 1);

                    caller.method(T, setter, info, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        return accessor;
    }
};

pub const Indexed = struct {
    getter: *const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime opts: Opts) Indexed {
        return .{ .getter = struct {
            fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller = Caller.init(v8_isolate);
                defer caller.deinit();

                const info = PropertyCallbackInfo{ .handle = handle.? };
                return caller.getIndex(T, getter, idx, info, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const NamedIndexed = struct {
    getter: *const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    setter: ?*const fn (c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    deleter: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, comptime opts: Opts) NamedIndexed {
        const getter_fn = struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller = Caller.init(v8_isolate);
                defer caller.deinit();

                const info = PropertyCallbackInfo{ .handle = handle.? };
                return caller.getNamedIndex(T, getter, .{ .handle = c_name.? }, info, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const setter_fn = if (@typeInfo(@TypeOf(setter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller = Caller.init(v8_isolate);
                defer caller.deinit();

                const info = PropertyCallbackInfo{ .handle = handle.? };
                return caller.setNamedIndex(T, setter, .{ .handle = c_name.? }, .{ .handle = c_value.? }, info, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const deleter_fn = if (@typeInfo(@TypeOf(deleter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller = Caller.init(v8_isolate);
                defer caller.deinit();

                const info = PropertyCallbackInfo{ .handle = handle.? };
                return caller.deleteNamedIndex(T, deleter, .{ .handle = c_name.? }, info, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        return .{
            .getter = getter_fn,
            .setter = setter_fn,
            .deleter = deleter_fn,
        };
    }
};

pub const Iterator = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
    async: bool,

    const Opts = struct {
        async: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime struct_or_func: anytype, comptime opts: Opts) Iterator {
        if (@typeInfo(@TypeOf(struct_or_func)) == .type) {
            return .{
                .async = opts.async,
                .func = struct {
                    fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                        const info = FunctionCallbackInfo{ .handle = handle.? };
                        info.getReturnValue().set(info.getThis());
                    }
                }.wrap,
            };
        }

        return .{
            .async = opts.async,
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller = Caller.init(v8_isolate);
                    defer caller.deinit();

                    const info = FunctionCallbackInfo{ .handle = handle.? };
                    caller.method(T, struct_or_func, info, .{});
                }
            }.wrap,
        };
    }
};

pub const Callable = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Callable {
        return .{ .func = struct {
            fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                var caller = Caller.init(v8_isolate);
                defer caller.deinit();

                const info = FunctionCallbackInfo{ .handle = handle.? };
                caller.method(T, func, info, .{
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const Property = union(enum) {
    int: i64,
};

pub fn unknownPropertyCallback(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    const isolate_handle = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
    const context = Context.fromIsolate(.{ .handle = isolate_handle });

    const property: []const u8 = context.valueToString(.{ .ctx = context, .handle = c_name.? }, .{}) catch {
        return 0;
    };

    const ignored = std.StaticStringMap(void).initComptime(.{
        .{ "process", {} },
        .{ "ShadyDOM", {} },
        .{ "ShadyCSS", {} },

        .{ "litNonce", {} },
        .{ "litHtmlVersions", {} },
        .{ "litElementVersions", {} },
        .{ "litHtmlPolyfillSupport", {} },
        .{ "litElementHydrateSupport", {} },
        .{ "litElementPolyfillSupport", {} },
        .{ "reactiveElementVersions", {} },

        .{ "recaptcha", {} },
        .{ "grecaptcha", {} },
        .{ "___grecaptcha_cfg", {} },
        .{ "__recaptcha_api", {} },
        .{ "__google_recaptcha_client", {} },

        .{ "CLOSURE_FLAGS", {} },
    });

    if (!ignored.has(property)) {
        const page = context.page;
        const document = page.document;

        if (document.getElementById(property, page)) |el| {
            const js_value = context.zigValueToJs(el, .{}) catch {
                return 0;
            };
            var pc = PropertyCallbackInfo{ .handle = handle.? };
            pc.getReturnValue().set(js_value);
            return 1;
        }

        if (comptime IS_DEBUG) {
            log.debug(.unknown_prop, "unknown global property", .{
                .info = "but the property can exist in pure JS",
                .stack = context.stackTrace() catch "???",
                .property = property,
            });
        }
    }

    // not intercepted
    return 0;
}

// Given a Type, returns the length of the prototype chain, including self
fn prototypeChainLength(comptime T: type) usize {
    var l: usize = 1;
    var Next = T;
    while (PrototypeType(Next)) |N| {
        Next = N;
        l += 1;
    }
    return l;
}

// Given a Type, gets its prototype Type (if any)
fn PrototypeType(comptime T: type) ?type {
    if (!@hasField(T, "_proto")) {
        return null;
    }
    return Struct(std.meta.fieldInfo(T, ._proto).type);
}

fn flattenTypes(comptime Types: []const type) [countFlattenedTypes(Types)]type {
    var index: usize = 0;
    var flat: [countFlattenedTypes(Types)]type = undefined;
    for (Types) |T| {
        if (@hasDecl(T, "registerTypes")) {
            for (T.registerTypes()) |TT| {
                flat[index] = TT.JsApi;
                index += 1;
            }
        } else {
            flat[index] = T.JsApi;
            index += 1;
        }
    }
    return flat;
}

fn countFlattenedTypes(comptime Types: []const type) usize {
    var c: usize = 0;
    for (Types) |T| {
        c += if (@hasDecl(T, "registerTypes")) T.registerTypes().len else 1;
    }
    return c;
}

//  T => T
// *T => T
pub fn Struct(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |ptr| ptr.child,
        else => @compileError("Expecting Struct or *Struct, got: " ++ @typeName(T)),
    };
}

pub const JsApiLookup = struct {
    /// Integer type we use for `JsApiLookup` enum. Can be u8 at min.
    pub const BackingInt = std.math.IntFittingRange(0, @max(std.math.maxInt(u8), JsApis.len));

    /// Imagine we have a type `Cat` which has a getter:
    ///
    ///    fn get_owner(self: *Cat) *Owner {
    ///        return self.owner;
    ///    }
    ///
    /// When we execute `caller.getter`, we'll end up doing something like:
    ///
    ///    const res = @call(.auto, Cat.get_owner, .{cat_instance});
    ///
    /// How do we turn `res`, which is an *Owner, into something we can return
    /// to v8? We need the ObjectTemplate associated with Owner. How do we
    /// get that? Well, we store all the ObjectTemplates in an array that's
    /// tied to env. So we do something like:
    ///
    ///    env.templates[index_of_owner].initInstance(...);
    ///
    /// But how do we get that `index_of_owner`? `Index` is an enum
    /// that looks like:
    ///
    ///    pub const Enum = enum(BackingInt) {
    ///        cat = 0,
    ///        owner = 1,
    ///        ...
    ///    }
    ///
    /// (`BackingInt` is calculated at comptime regarding to interfaces we have)
    /// So to get the template index of `owner`, simply do:
    ///
    ///    const index_id = types.getId(@TypeOf(res));
    ///
    pub const Enum = blk: {
        var fields: [JsApis.len]std.builtin.Type.EnumField = undefined;
        for (JsApis, 0..) |JsApi, i| {
            fields[i] = .{ .name = @typeName(JsApi), .value = i };
        }

        break :blk @Type(.{
            .@"enum" = .{
                .fields = &fields,
                .tag_type = BackingInt,
                .is_exhaustive = true,
                .decls = &.{},
            },
        });
    };

    /// Returns a boolean indicating if a type exist in the lookup.
    pub inline fn has(t: type) bool {
        return @hasField(Enum, @typeName(t));
    }

    /// Returns the `Enum` for the given type.
    pub inline fn getIndex(t: type) Enum {
        return @field(Enum, @typeName(t));
    }

    /// Returns the ID for the given type.
    pub inline fn getId(t: type) BackingInt {
        return @intFromEnum(getIndex(t));
    }
};

pub const SubType = enum {
    @"error",
    array,
    arraybuffer,
    dataview,
    date,
    generator,
    iterator,
    map,
    node,
    promise,
    proxy,
    regexp,
    set,
    typedarray,
    wasmvalue,
    weakmap,
    weakset,
    webassemblymemory,
};

pub const JsApis = flattenTypes(&.{
    @import("../webapi/AbortController.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/CData.zig"),
    @import("../webapi/cdata/Comment.zig"),
    @import("../webapi/cdata/Text.zig"),
    @import("../webapi/cdata/CDATASection.zig"),
    @import("../webapi/cdata/ProcessingInstruction.zig"),
    @import("../webapi/collections.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/CSS.zig"),
    @import("../webapi/css/CSSRule.zig"),
    @import("../webapi/css/CSSRuleList.zig"),
    @import("../webapi/css/CSSStyleDeclaration.zig"),
    @import("../webapi/css/CSSStyleRule.zig"),
    @import("../webapi/css/CSSStyleSheet.zig"),
    @import("../webapi/css/CSSStyleProperties.zig"),
    @import("../webapi/css/MediaQueryList.zig"),
    @import("../webapi/css/StyleSheetList.zig"),
    @import("../webapi/Document.zig"),
    @import("../webapi/HTMLDocument.zig"),
    @import("../webapi/XMLDocument.zig"),
    @import("../webapi/History.zig"),
    @import("../webapi/KeyValueList.zig"),
    @import("../webapi/DocumentFragment.zig"),
    @import("../webapi/DocumentType.zig"),
    @import("../webapi/ShadowRoot.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/DOMImplementation.zig"),
    @import("../webapi/DOMTreeWalker.zig"),
    @import("../webapi/DOMNodeIterator.zig"),
    @import("../webapi/DOMRect.zig"),
    @import("../webapi/DOMParser.zig"),
    @import("../webapi/XMLSerializer.zig"),
    @import("../webapi/AbstractRange.zig"),
    @import("../webapi/Range.zig"),
    @import("../webapi/NodeFilter.zig"),
    @import("../webapi/Element.zig"),
    @import("../webapi/element/DOMStringMap.zig"),
    @import("../webapi/element/Attribute.zig"),
    @import("../webapi/element/Html.zig"),
    @import("../webapi/element/html/IFrame.zig"),
    @import("../webapi/element/html/Anchor.zig"),
    @import("../webapi/element/html/Area.zig"),
    @import("../webapi/element/html/Audio.zig"),
    @import("../webapi/element/html/Base.zig"),
    @import("../webapi/element/html/Body.zig"),
    @import("../webapi/element/html/BR.zig"),
    @import("../webapi/element/html/Button.zig"),
    @import("../webapi/element/html/Canvas.zig"),
    @import("../webapi/element/html/Custom.zig"),
    @import("../webapi/element/html/Data.zig"),
    @import("../webapi/element/html/DataList.zig"),
    @import("../webapi/element/html/Dialog.zig"),
    @import("../webapi/element/html/Directory.zig"),
    @import("../webapi/element/html/Div.zig"),
    @import("../webapi/element/html/Embed.zig"),
    @import("../webapi/element/html/FieldSet.zig"),
    @import("../webapi/element/html/Font.zig"),
    @import("../webapi/element/html/Form.zig"),
    @import("../webapi/element/html/Generic.zig"),
    @import("../webapi/element/html/Head.zig"),
    @import("../webapi/element/html/Heading.zig"),
    @import("../webapi/element/html/HR.zig"),
    @import("../webapi/element/html/Html.zig"),
    @import("../webapi/element/html/Image.zig"),
    @import("../webapi/element/html/Input.zig"),
    @import("../webapi/element/html/Label.zig"),
    @import("../webapi/element/html/Legend.zig"),
    @import("../webapi/element/html/LI.zig"),
    @import("../webapi/element/html/Link.zig"),
    @import("../webapi/element/html/Map.zig"),
    @import("../webapi/element/html/Media.zig"),
    @import("../webapi/element/html/Meta.zig"),
    @import("../webapi/element/html/Meter.zig"),
    @import("../webapi/element/html/Mod.zig"),
    @import("../webapi/element/html/Object.zig"),
    @import("../webapi/element/html/OL.zig"),
    @import("../webapi/element/html/OptGroup.zig"),
    @import("../webapi/element/html/Option.zig"),
    @import("../webapi/element/html/Output.zig"),
    @import("../webapi/element/html/Paragraph.zig"),
    @import("../webapi/element/html/Param.zig"),
    @import("../webapi/element/html/Pre.zig"),
    @import("../webapi/element/html/Progress.zig"),
    @import("../webapi/element/html/Quote.zig"),
    @import("../webapi/element/html/Script.zig"),
    @import("../webapi/element/html/Select.zig"),
    @import("../webapi/element/html/Slot.zig"),
    @import("../webapi/element/html/Source.zig"),
    @import("../webapi/element/html/Span.zig"),
    @import("../webapi/element/html/Style.zig"),
    @import("../webapi/element/html/Table.zig"),
    @import("../webapi/element/html/TableCaption.zig"),
    @import("../webapi/element/html/TableCell.zig"),
    @import("../webapi/element/html/TableCol.zig"),
    @import("../webapi/element/html/TableRow.zig"),
    @import("../webapi/element/html/TableSection.zig"),
    @import("../webapi/element/html/Template.zig"),
    @import("../webapi/element/html/TextArea.zig"),
    @import("../webapi/element/html/Time.zig"),
    @import("../webapi/element/html/Title.zig"),
    @import("../webapi/element/html/Track.zig"),
    @import("../webapi/element/html/Video.zig"),
    @import("../webapi/element/html/UL.zig"),
    @import("../webapi/element/html/Unknown.zig"),
    @import("../webapi/element/Svg.zig"),
    @import("../webapi/element/svg/Generic.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/CompositionEvent.zig"),
    @import("../webapi/event/CustomEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    @import("../webapi/event/NavigationCurrentEntryChangeEvent.zig"),
    @import("../webapi/event/PageTransitionEvent.zig"),
    @import("../webapi/event/PopStateEvent.zig"),
    @import("../webapi/event/UIEvent.zig"),
    @import("../webapi/event/MouseEvent.zig"),
    @import("../webapi/event/KeyboardEvent.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/media/MediaError.zig"),
    @import("../webapi/media/TextTrackCue.zig"),
    @import("../webapi/media/VTTCue.zig"),
    @import("../webapi/animation/Animation.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Location.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/Node.zig"),
    @import("../webapi/storage/storage.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/Window.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/MutationObserver.zig"),
    @import("../webapi/IntersectionObserver.zig"),
    @import("../webapi/CustomElementRegistry.zig"),
    @import("../webapi/ResizeObserver.zig"),
    @import("../webapi/IdleDeadline.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/Screen.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/navigation/Navigation.zig"),
    @import("../webapi/navigation/NavigationEventTarget.zig"),
    @import("../webapi/navigation/NavigationHistoryEntry.zig"),
    @import("../webapi/navigation/NavigationActivation.zig"),
    @import("../webapi/canvas/CanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/SubtleCrypto.zig"),
});

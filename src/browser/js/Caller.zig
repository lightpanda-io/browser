const std = @import("std");
const js = @import("js.zig");
const v8 = js.v8;

const log = @import("../../log.zig");
const Page = @import("../page.zig").Page;

const types = @import("types.zig");
const Context = @import("Context.zig");

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

    // Set this _after_ we've executed the above code, so that if the
    // above code executes any callbacks, they aren't being executed
    // at scope 0, which would be wrong.
    context.call_depth = call_depth;
}

pub fn constructor(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, info: v8.FunctionCallbackInfo) !void {
    const args = try self.getArgs(Struct, named_function, 0, info);
    const res = @call(.auto, Struct.constructor, args);

    const ReturnType = @typeInfo(@TypeOf(Struct.constructor)).@"fn".return_type orelse {
        @compileError(@typeName(Struct) ++ " has a constructor without a return type");
    };

    const this = info.getThis();
    if (@typeInfo(ReturnType) == .error_union) {
        const non_error_res = res catch |err| return err;
        _ = try self.context.mapZigInstanceToJs(this, non_error_res);
    } else {
        _ = try self.context.mapZigInstanceToJs(this, res);
    }
    info.getReturnValue().set(this);
}

pub fn method(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, info: v8.FunctionCallbackInfo) !void {
    if (comptime isSelfReceiver(Struct, named_function) == false) {
        return self.function(Struct, named_function, info);
    }

    const context = self.context;
    const func = @field(Struct, named_function.name);
    var args = try self.getArgs(Struct, named_function, 1, info);
    const zig_instance = try context.typeTaggedAnyOpaque(named_function, *types.Receiver(Struct), info.getThis());

    // inject 'self' as the first parameter
    @field(args, "0") = zig_instance;

    const res = @call(.auto, func, args);
    info.getReturnValue().set(try context.zigValueToJs(res));
}

pub fn function(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, info: v8.FunctionCallbackInfo) !void {
    const context = self.context;
    const func = @field(Struct, named_function.name);
    const args = try self.getArgs(Struct, named_function, 0, info);
    const res = @call(.auto, func, args);
    info.getReturnValue().set(try context.zigValueToJs(res));
}

pub fn getIndex(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, idx: u32, info: v8.PropertyCallbackInfo) !u8 {
    const context = self.context;
    const func = @field(Struct, named_function.name);
    const IndexedGet = @TypeOf(func);
    if (@typeInfo(IndexedGet).@"fn".return_type == null) {
        @compileError(named_function.full_name ++ " must have a return type");
    }

    var has_value = true;

    var args: ParamterTypes(IndexedGet) = undefined;
    const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    switch (arg_fields.len) {
        0, 1, 2 => @compileError(named_function.full_name ++ " must take at least a u32 and *bool parameter"),
        3, 4 => {
            const zig_instance = try context.typeTaggedAnyOpaque(named_function, *types.Receiver(Struct), info.getThis());
            comptime assertSelfReceiver(Struct, named_function);
            @field(args, "0") = zig_instance;
            @field(args, "1") = idx;
            @field(args, "2") = &has_value;
            if (comptime arg_fields.len == 4) {
                comptime assertIsPageArg(Struct, named_function, 3);
                @field(args, "3") = context.page;
            }
        },
        else => @compileError(named_function.full_name ++ " has too many parmaters"),
    }

    const res = @call(.auto, func, args);
    if (has_value == false) {
        return v8.Intercepted.No;
    }
    info.getReturnValue().set(try context.zigValueToJs(res));
    return v8.Intercepted.Yes;
}

pub fn getNamedIndex(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, name: v8.Name, info: v8.PropertyCallbackInfo) !u8 {
    const context = self.context;
    const func = @field(Struct, named_function.name);
    comptime assertSelfReceiver(Struct, named_function);

    var has_value = true;
    var args = try self.getArgs(Struct, named_function, 3, info);
    const zig_instance = try context.typeTaggedAnyOpaque(named_function, *types.Receiver(Struct), info.getThis());
    @field(args, "0") = zig_instance;
    @field(args, "1") = try self.nameToString(name);
    @field(args, "2") = &has_value;

    const res = @call(.auto, func, args);
    if (has_value == false) {
        return v8.Intercepted.No;
    }
    info.getReturnValue().set(try self.context.zigValueToJs(res));
    return v8.Intercepted.Yes;
}

pub fn setNamedIndex(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, name: v8.Name, js_value: v8.Value, info: v8.PropertyCallbackInfo) !u8 {
    const context = self.context;
    const func = @field(Struct, named_function.name);
    comptime assertSelfReceiver(Struct, named_function);

    var has_value = true;
    var args = try self.getArgs(Struct, named_function, 4, info);
    const zig_instance = try context.typeTaggedAnyOpaque(named_function, *types.Receiver(Struct), info.getThis());
    @field(args, "0") = zig_instance;
    @field(args, "1") = try self.nameToString(name);
    @field(args, "2") = try context.jsValueToZig(named_function, @TypeOf(@field(args, "2")), js_value);
    @field(args, "3") = &has_value;

    const res = @call(.auto, func, args);
    return namedSetOrDeleteCall(res, has_value);
}

pub fn deleteNamedIndex(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, name: v8.Name, info: v8.PropertyCallbackInfo) !u8 {
    const context = self.context;
    const func = @field(Struct, named_function.name);
    comptime assertSelfReceiver(Struct, named_function);

    var has_value = true;
    var args = try self.getArgs(Struct, named_function, 3, info);
    const zig_instance = try context.typeTaggedAnyOpaque(named_function, *types.Receiver(Struct), info.getThis());
    @field(args, "0") = zig_instance;
    @field(args, "1") = try self.nameToString(name);
    @field(args, "2") = &has_value;

    const res = @call(.auto, func, args);
    return namedSetOrDeleteCall(res, has_value);
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

fn isSelfReceiver(comptime Struct: type, comptime named_function: NamedFunction) bool {
    return checkSelfReceiver(Struct, named_function, false);
}
fn assertSelfReceiver(comptime Struct: type, comptime named_function: NamedFunction) void {
    _ = checkSelfReceiver(Struct, named_function, true);
}
fn checkSelfReceiver(comptime Struct: type, comptime named_function: NamedFunction, comptime fail: bool) bool {
    const func = @field(Struct, named_function.name);
    const params = @typeInfo(@TypeOf(func)).@"fn".params;
    if (params.len == 0) {
        if (fail) {
            @compileError(named_function.full_name ++ " must have a self parameter");
        }
        return false;
    }

    const R = types.Receiver(Struct);
    const first_param = params[0].type.?;
    if (first_param != *R and first_param != *const R) {
        if (fail) {
            @compileError(std.fmt.comptimePrint("The first parameter to {s} must be a *{s} or *const {s}. Got: {s}", .{
                named_function.full_name,
                @typeName(R),
                @typeName(R),
                @typeName(first_param),
            }));
        }
        return false;
    }
    return true;
}

fn assertIsPageArg(comptime Struct: type, comptime named_function: NamedFunction, index: comptime_int) void {
    const F = @TypeOf(@field(Struct, named_function.name));
    const param = @typeInfo(F).@"fn".params[index].type.?;
    if (isPage(param)) {
        return;
    }
    @compileError(std.fmt.comptimePrint("The {d} parameter to {s} must be a *Page or *const Page. Got: {s}", .{ index, named_function.full_name, @typeName(param) }));
}

pub fn handleError(self: *Caller, comptime Struct: type, comptime named_function: NamedFunction, err: anyerror, info: anytype) void {
    const isolate = self.isolate;

    if (comptime @import("builtin").mode == .Debug and @hasDecl(@TypeOf(info), "length")) {
        if (log.enabled(.js, .warn)) {
            self.logFunctionCallError(err, named_function.full_name, info);
        }
    }

    var js_err: ?v8.Value = switch (err) {
        error.InvalidArgument => createTypeException(isolate, "invalid argument"),
        error.OutOfMemory => js._createException(isolate, "out of memory"),
        error.IllegalConstructor => js._createException(isolate, "Illegal Contructor"),
        else => blk: {
            const func = @field(Struct, named_function.name);
            const return_type = @typeInfo(@TypeOf(func)).@"fn".return_type orelse {
                // void return type;
                break :blk null;
            };

            if (@typeInfo(return_type) != .error_union) {
                // type defines a custom exception, but this function should
                // not fail. We failed somewhere inside of js.zig and
                // should return the error as-is, since it isn't related
                // to our Struct
                break :blk null;
            }

            const function_error_set = @typeInfo(return_type).error_union.error_set;

            const E = comptime getCustomException(Struct) orelse break :blk null;
            if (function_error_set == E or isErrorSetException(E, err)) {
                const custom_exception = E.init(self.call_arena, err, named_function.js_name) catch |init_err| {
                    switch (init_err) {
                        // if a custom exceptions' init wants to return a
                        // different error, we need to think about how to
                        // handle that failure.
                        error.OutOfMemory => break :blk js._createException(isolate, "out of memory"),
                    }
                };
                // ughh..how to handle an error here?
                break :blk self.context.zigValueToJs(custom_exception) catch js._createException(isolate, "internal error");
            }
            // this error isn't part of a custom exception
            break :blk null;
        },
    };

    if (js_err == null) {
        js_err = js._createException(isolate, @errorName(err));
    }
    const js_exception = isolate.throwException(js_err.?);
    info.getReturnValue().setValueHandle(js_exception.handle);
}

// walk the prototype chain to see if a type declares a custom Exception
fn getCustomException(comptime Struct: type) ?type {
    var S = Struct;
    while (true) {
        if (@hasDecl(S, "Exception")) {
            return S.Exception;
        }
        if (@hasDecl(S, "prototype") == false) {
            return null;
        }
        // long ago, we validated that every prototype declaration
        // is a pointer.
        S = @typeInfo(S.prototype).pointer.child;
    }
}

// Does the error we want to return belong to the custom exeception's ErrorSet
fn isErrorSetException(comptime E: type, err: anytype) bool {
    const Entry = std.meta.Tuple(&.{ []const u8, void });

    const error_set = @typeInfo(E.ErrorSet).error_set.?;
    const entries = comptime blk: {
        var kv: [error_set.len]Entry = undefined;
        for (error_set, 0..) |e, i| {
            kv[i] = .{ e.name, {} };
        }
        break :blk kv;
    };
    const lookup = std.StaticStringMap(void).initComptime(entries);
    return lookup.has(@errorName(err));
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
fn getArgs(self: *const Caller, comptime Struct: type, comptime named_function: NamedFunction, comptime offset: usize, info: anytype) !ParamterTypes(@TypeOf(@field(Struct, named_function.name))) {
    const context = self.context;
    const F = @TypeOf(@field(Struct, named_function.name));
    var args: ParamterTypes(F) = undefined;

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
                        a.* = try context.jsValueToZig(named_function, slice_type, js_value);
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
            @compileError("Page must be the last parameter (or 2nd last if there's a JsThis): " ++ named_function.full_name);
        } else if (comptime param.type.? == js.This) {
            @compileError("JsThis must be the last parameter: " ++ named_function.full_name);
        } else if (i >= js_parameter_count) {
            if (@typeInfo(param.type.?) != .optional) {
                return error.InvalidArgument;
            }
            @field(args, tupleFieldName(field_index)) = null;
        } else {
            const js_value = info.getArg(@as(u32, @intCast(i)));
            @field(args, tupleFieldName(field_index)) = context.jsValueToZig(named_function, param.type.?, js_value) catch {
                return error.InvalidArgument;
            };
        }
    }

    return args;
}

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(self: *Caller, err: anyerror, function_name: []const u8, info: v8.FunctionCallbackInfo) void {
    const args_dump = self.serializeFunctionArgs(info) catch "failed to serialize args";
    log.info(.js, "function call error", .{
        .name = function_name,
        .err = err,
        .args = args_dump,
        .stack = self.context.stackTrace() catch |err1| @errorName(err1),
    });
}

fn serializeFunctionArgs(self: *Caller, info: v8.FunctionCallbackInfo) ![]const u8 {
    const separator = log.separator();
    const js_parameter_count = info.length();

    const context = self.context;
    var arr: std.ArrayListUnmanaged(u8) = .{};
    for (0..js_parameter_count) |i| {
        const js_value = info.getArg(@intCast(i));
        const value_string = try context.valueToDetailString(js_value);
        const value_type = try context.jsStringToZig(try js_value.typeOf(self.isolate), .{});
        try std.fmt.format(arr.writer(context.call_arena), "{s}{d}: {s} ({s})", .{
            separator,
            i + 1,
            value_string,
            value_type,
        });
    }
    return arr.items;
}

// We want the function name, or more precisely, the "Struct.function" for
// displaying helpful @compileError.
// However, there's no way to get the name from a std.Builtin.Fn, so we create
// a NamedFunction as part of our binding, and pass it around incase we need
// to display an error
pub const NamedFunction = struct {
    name: []const u8,
    js_name: []const u8,
    full_name: []const u8,

    pub fn init(comptime Struct: type, comptime name: []const u8) NamedFunction {
        return .{
            .name = name,
            .js_name = if (name[0] == '_') name[1..] else name,
            .full_name = @typeName(Struct) ++ "." ++ name,
        };
    }
};

// Takes a function, and returns a tuple for its argument. Used when we
// @call a function
fn ParamterTypes(comptime F: type) type {
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

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

// JS -> Zig call marshaling. See v8/Caller.zig; the structure is kept as
// close as practical.
const std = @import("std");
const lp = @import("lightpanda");
const string = @import("../../../string.zig");

const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const Session = @import("../../Session.zig");

const js = @import("js.zig");
const Local = @import("Local.zig");
const Context = @import("Context.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const q = js.q;
const log = lp.log;
const ArenaAllocator = std.heap.ArenaAllocator;
const CALL_ARENA_RETAIN = 1024 * 16;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Caller = @This();

local: Local,
prev_local: ?*const js.Local,
prev_context: *Context,
handle_mark: usize,

pub fn init(self: *Caller, qctx: *q.JSContext) bool {
    const opq = q.JS_GetContextOpaque(qctx) orelse {
        const ex = q.JS_ThrowPlainError(qctx, "Cannot execute in detached context");
        q.JS_FreeValue(qctx, ex);
        return false;
    };
    self.initWithContext(@ptrCast(@alignCast(opq)));
    return true;
}

pub fn initWithContext(self: *Caller, ctx: *Context) void {
    ctx.call_depth += 1;
    self.* = Caller{
        .local = .{
            .ctx = ctx,
            .call_arena = ctx.call_arena,
        },
        .prev_local = ctx.local,
        .prev_context = ctx.global.getJs(),
        .handle_mark = ctx.handleMark(),
    };
    ctx.global.setJs(ctx);
    ctx.local = &self.local;
}

pub fn deinit(self: *Caller) void {
    const ctx = self.local.ctx;
    const call_depth = ctx.call_depth - 1;

    ctx.freeHandles(self.handle_mark);

    // see v8/Caller.zig: only reset the call_arena once the outermost call
    // completes (calls can nest via callbacks).
    if (call_depth == 0) {
        const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx.call_arena.ptr));
        _ = arena.reset(.{ .retain_with_limit = CALL_ARENA_RETAIN });
    }

    ctx.call_depth = call_depth;
    ctx.local = self.prev_local;
    ctx.global.setJs(self.prev_context);
}

pub const CallOpts = struct {
    dom_exception: bool = false,
    null_as_undefined: bool = false,
    as_typed_array: bool = false,
    new_target: bool = false,
};

pub fn constructor(comptime T: type, comptime func: anytype, qctx: *q.JSContext, new_target: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, comptime opts: CallOpts) q.JSValue {
    var caller: Caller = undefined;
    if (!caller.init(qctx)) {
        return js.EXCEPTION;
    }
    defer caller.deinit();

    // Constructors are a JS-execution boundary; see v8/bridge.zig.
    const ce_frame: ?*Frame = switch (caller.local.ctx.global) {
        .frame => |frame| frame,
        .worker => null,
    };
    const ce_checkpoint: usize = if (ce_frame) |frame| frame._ce_reactions.push() else 0;
    defer if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);

    return caller._constructor(T, func, new_target, argsSlice(argc, argv), opts) catch |err| {
        return handleError(T, @TypeOf(func), &caller.local, err, opts);
    };
}

fn _constructor(self: *Caller, comptime T: type, comptime func: anytype, new_target: q.JSValueConst, js_args: []const q.JSValue, comptime opts: CallOpts) !q.JSValue {
    const F = @TypeOf(func);
    const local = &self.local;
    const qctx = local.ctx.ctx;

    const offset: comptime_int = if (opts.new_target) 1 else 0;
    var args = try getArgs(F, offset, local, js_args);
    if (comptime opts.new_target) {
        @field(args, "0") = js.Function{ .local = local, .handle = new_target };
    }
    const res = @call(.auto, func, args);

    const ReturnType = @typeInfo(F).@"fn".return_type orelse {
        @compileError(@typeName(F) ++ " has a constructor without a return type");
    };

    const this = blk: {
        if (@typeInfo(ReturnType) == .error_union) {
            break :blk try local.mapZigInstanceToJs(null, try res);
        }
        break :blk try local.mapZigInstanceToJs(null, res);
    };

    // Honor a subclass' prototype (e.g. `new MyElement()` where MyElement
    // extends HTMLElement). The v8 backend gets this from the new-target's
    // template; here we copy the prototype explicitly.
    if (!q.JS_IsUndefined(new_target)) {
        const proto = q.JS_GetPropertyStr(qctx, new_target, "prototype");
        defer q.JS_FreeValue(qctx, proto);
        if (q.JS_IsObject(proto)) {
            _ = q.JS_SetPrototype(qctx, this.handle, proto);
        }
    }

    _ = T;
    return q.JS_DupValue(qctx, this.handle);
}

// The exotic get_own_property handler outcome.
pub const IndexedResult = struct {
    handled: bool,
    value: q.JSValue = js.UNDEFINED,
};

pub fn getIndex(self: *Caller, comptime T: type, comptime func: anytype, js_this: q.JSValueConst, idx: u32, comptime opts: CallOpts) !IndexedResult {
    const local = &self.local;
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, local.ctx, js_this);
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, true, ret, opts);
}

// Calls a collection's index enumerator (e.g. NodeList.getIndexes), which
// returns a js.Array of the exposed indices. Used by the exotic
// get_own_property_names handler so Object.keys / for..in / spread see them.
pub fn getEnumerator(self: *Caller, comptime T: type, comptime func: anytype, js_this: q.JSValueConst) !js.Array {
    const local = &self.local;
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, local.ctx, js_this);
    if (@typeInfo(F).@"fn".params.len == 2) {
        @field(args, "1") = getGlobalArg(@TypeOf(args.@"1"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return switch (@typeInfo(@TypeOf(ret))) {
        .error_union => try ret,
        else => ret,
    };
}

pub fn getNamedIndex(self: *Caller, comptime T: type, comptime func: anytype, js_this: q.JSValueConst, name_atom: q.JSAtom, comptime opts: CallOpts) !IndexedResult {
    const local = &self.local;
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, local.ctx, js_this);
    @field(args, "1") = try atomToString(local, @TypeOf(args.@"1"), name_atom);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, true, ret, opts);
}

pub fn setNamedIndex(self: *Caller, comptime T: type, comptime func: anytype, js_this: q.JSValueConst, name_atom: q.JSAtom, js_value: q.JSValueConst, comptime opts: CallOpts) !IndexedResult {
    const local = &self.local;
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, local.ctx, js_this);
    @field(args, "1") = try atomToString(local, @TypeOf(args.@"1"), name_atom);
    @field(args, "2") = try local.jsValueToZig(@TypeOf(@field(args, "2")), .{ .local = local, .handle = js_value });
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = getGlobalArg(@TypeOf(args.@"3"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, false, ret, opts);
}

pub fn deleteNamedIndex(self: *Caller, comptime T: type, comptime func: anytype, js_this: q.JSValueConst, name_atom: q.JSAtom, comptime opts: CallOpts) !IndexedResult {
    const local = &self.local;
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, local.ctx, js_this);
    @field(args, "1") = try atomToString(local, @TypeOf(args.@"1"), name_atom);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return self.handleIndexedReturn(T, F, false, ret, opts);
}

fn handleIndexedReturn(self: *Caller, comptime T: type, comptime F: type, comptime with_value: bool, ret: anytype, comptime opts: CallOpts) !IndexedResult {
    _ = T;
    _ = F;
    const non_error_ret = switch (@typeInfo(@TypeOf(ret))) {
        .error_union => |eu| blk: {
            break :blk ret catch |err| {
                if (comptime isInErrorSet(error.NotHandled, eu.error_set)) {
                    if (err == error.NotHandled) {
                        return .{ .handled = false };
                    }
                }
                return err;
            };
        },
        else => ret,
    };

    if (comptime with_value) {
        const value = try self.local.zigValueToJs(non_error_ret, opts);
        return .{ .handled = true, .value = value.handle };
    }
    return .{ .handled = true };
}

fn isInErrorSet(comptime err: anyerror, comptime T: type) bool {
    inline for (@typeInfo(T).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

fn atomToString(local: *const Local, comptime T: type, atom: q.JSAtom) !T {
    const qctx = local.ctx.ctx;
    var len: usize = 0;
    const cstr = q.JS_AtomToCStringLen(qctx, &len, atom) orelse return error.InvalidArgument;
    defer q.JS_FreeCString(qctx, cstr);
    const slice = cstr[0..len];

    if (T == string.String) {
        return @import("String.zig").sliceToSSO(slice, local.call_arena);
    }
    if (T == string.Global) {
        return .{ .str = try @import("String.zig").sliceToSSO(slice, local.ctx.page.frame_arena) };
    }
    return try local.call_arena.dupe(u8, slice);
}

pub fn handleError(comptime T: type, comptime F: type, local: *const Local, err: anyerror, comptime opts: CallOpts) q.JSValue {
    const qctx = local.ctx.ctx;

    if (comptime IS_DEBUG) {
        if (log.enabled(.js, .debug)) {
            const DOMException = @import("../../webapi/DOMException.zig");
            if (DOMException.fromError(err) == null) {
                log.debug(.js, "function call error", .{
                    .type = @typeName(T),
                    .func = @typeName(F),
                    .err = err,
                });
            }
        }
    }

    switch (err) {
        error.TryCatchRethrow => return js.EXCEPTION,
        error.JsException => return js.EXCEPTION,
        error.InvalidArgument => return q.JS_ThrowTypeError(qctx, "invalid argument"),
        error.TypeError => return q.JS_ThrowTypeError(qctx, "%s", ""),
        error.Idna => return q.JS_ThrowTypeError(qctx, "invalid domain"),
        error.RangeError => return q.JS_ThrowRangeError(qctx, "%s", ""),
        error.OutOfMemory => return q.JS_ThrowPlainError(qctx, "out of memory"),
        error.IllegalConstructor => return q.JS_ThrowPlainError(qctx, "Illegal Constructor"),
        else => {
            if (comptime opts.dom_exception) {
                const DOMException = @import("../../webapi/DOMException.zig");
                if (DOMException.fromError(err)) |ex| {
                    const value = local.zigValueToJs(ex, .{}) catch {
                        return q.JS_ThrowPlainError(qctx, "internal error");
                    };
                    return q.JS_Throw(qctx, q.JS_DupValue(qctx, value.handle));
                }
            }
            return q.JS_ThrowPlainError(qctx, "%s", @errorName(err).ptr);
        },
    }
}

pub fn argsSlice(argc: c_int, argv: [*c]const q.JSValueConst) []const q.JSValue {
    if (argc <= 0) {
        return &.{};
    }
    return argv[0..@intCast(argc)];
}

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

    if (comptime isSession(T)) {
        return ctx.page.session;
    }

    if (comptime isExecution(T)) {
        return &ctx.execution;
    }

    @compileError("Unsupported global arg type: " ++ @typeName(T));
}

pub const Function = struct {
    pub const Opts = struct {
        noop: bool = false,
        static: bool = false,
        wpt_only: bool = false,
        deletable: bool = true,
        dom_exception: bool = false,
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        // The v8 backend can cache accessor results directly in the
        // v8::Object; quickjs has no equivalent slot, so caching is
        // accepted (so JsApi declarations compile) and ignored.
        cache: ?Caching = null,
        embedded_receiver: bool = false,
        exposed: Exposed = .both,
        ce_reactions: bool = false,

        pub const Exposed = enum { both, window, worker };

        pub const Caching = union(enum) {
            internal: u8,
            private: []const u8,
        };
    };

    pub fn call(comptime T: type, qctx: *q.JSContext, js_this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, comptime func: anytype, comptime opts: Opts) q.JSValue {
        return callWithData(T, qctx, js_this, argc, argv, func, opts, null);
    }

    pub fn callWithData(comptime T: type, qctx: *q.JSContext, js_this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, comptime func: anytype, comptime opts: Opts, data: ?*anyopaque) q.JSValue {
        var caller: Caller = undefined;
        if (!caller.init(qctx)) {
            return js.EXCEPTION;
        }
        defer caller.deinit();

        const ctx = caller.local.ctx;

        // [CEReactions] entry: see v8/Caller.zig.
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

        const js_value = _call(T, &caller.local, js_this, argsSlice(argc, argv), func, opts, data) catch |err| {
            return handleError(T, @TypeOf(func), &caller.local, err, .{
                .dom_exception = opts.dom_exception,
                .as_typed_array = opts.as_typed_array,
                .null_as_undefined = opts.null_as_undefined,
            });
        };

        return q.JS_DupValue(qctx, js_value.handle);
    }

    fn _call(comptime T: type, local: *const Local, js_this: q.JSValueConst, js_args: []const q.JSValue, comptime func: anytype, comptime opts: Opts, data: ?*anyopaque) !js.Value {
        const F = @TypeOf(func);
        var args: ParameterTypes(F) = undefined;
        if (comptime opts.static) {
            args = try getArgs(F, 0, local, js_args);
        } else if (comptime opts.embedded_receiver) {
            args = try getArgs(F, 1, local, js_args);
            @field(args, "0") = @ptrCast(@alignCast(data orelse unreachable));
        } else {
            args = try getArgs(F, 1, local, js_args);
            @field(args, "0") = try TaggedOpaque.fromJS(*T, local.ctx, js_this);
        }
        const res = @call(.auto, func, args);
        return local.zigValueToJs(res, .{
            .dom_exception = opts.dom_exception,
            .as_typed_array = opts.as_typed_array,
            .null_as_undefined = opts.null_as_undefined,
        });
    }
};

// See v8/Caller.zig getArgs for the full semantics (trailing global-arg
// injection, variadic slurping, optional back-filling).
pub fn getArgs(comptime F: type, comptime offset: usize, local: *const Local, js_args: []const q.JSValue) !ParameterTypes(F) {
    var args: ParameterTypes(F) = undefined;

    const params = @typeInfo(F).@"fn".params[offset..];
    const params_to_map = blk: {
        if (params.len == 0) {
            return args;
        }

        const LastParamType = params[params.len - 1].type.?;
        if (comptime isFrame(LastParamType) or isPage(LastParamType) or isExecution(LastParamType) or isSession(LastParamType)) {
            @field(args, tupleFieldName(params.len - 1 + offset)) = getGlobalArg(LastParamType, local.ctx);
            break :blk params[0 .. params.len - 1];
        }

        break :blk params;
    };

    if (params_to_map.len == 0) {
        return args;
    }

    const js_parameter_count = js_args.len;
    const last_js_parameter = params_to_map.len - 1;
    var is_variadic = false;

    {
        // If the last Zig parameter is a slice AND the corresponding js
        // parameter is NOT an array, treat it as variadic.
        const last_parameter_type = params_to_map[params_to_map.len - 1].type.?;
        const last_parameter_type_info = @typeInfo(last_parameter_type);
        if (last_parameter_type_info == .pointer and last_parameter_type_info.pointer.size == .slice) {
            const slice_type = last_parameter_type_info.pointer.child;
            const corresponding_js_value = js.Value{
                .local = local,
                .handle = if (last_js_parameter < js_args.len) js_args[last_js_parameter] else js.UNDEFINED,
            };
            if (slice_type == js.Value or (corresponding_js_value.isArray() == false and corresponding_js_value.isTypedArray() == false and slice_type != u8)) {
                is_variadic = true;
                if (js_parameter_count == 0) {
                    @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
                } else if (js_parameter_count >= params_to_map.len) {
                    const arr = try local.call_arena.alloc(last_parameter_type_info.pointer.child, js_parameter_count - params_to_map.len + 1);
                    for (arr, last_js_parameter..) |*a, i| {
                        a.* = try local.jsValueToZig(slice_type, .{ .local = local, .handle = js_args[i] });
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
            const js_val = js.Value{ .local = local, .handle = js_args[i] };
            @field(args, tupleFieldName(field_index)) = local.jsValueToZig(param.type.?, js_val) catch |err| {
                const DOMException = @import("../../webapi/DOMException.zig");
                if (DOMException.fromError(err) != null) {
                    return err;
                }
                return error.InvalidArgument;
            };
        }
    }

    return args;
}

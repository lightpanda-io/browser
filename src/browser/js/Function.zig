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

const Allocator = std.mem.Allocator;

const Function = @This();

ctx: *js.Context,
this: ?*const v8.c.Object = null,
handle: *const v8.c.Function,

pub const Result = struct {
    stack: ?[]const u8,
    exception: []const u8,
};

pub fn id(self: *const Function) u32 {
    return @as(u32, @bitCast(v8.c.v8__Object__GetIdentityHash(@ptrCast(self.handle))));
}

pub fn withThis(self: *const Function, value: anytype) !Function {
    const this_obj = if (@TypeOf(value) == js.Object)
        value.handle
    else
        (try self.ctx.zigValueToJs(value, .{})).handle;

    return .{
        .ctx = self.ctx,
        .this = this_obj,
        .handle = self.handle,
    };
}

pub fn newInstance(self: *const Function, result: *Result) !js.Object {
    const ctx = self.ctx;

    var try_catch: js.TryCatch = undefined;
    try_catch.init(ctx);
    defer try_catch.deinit();

    // This creates a new instance using this Function as a constructor.
    // const c_args = @as(?[*]const ?*c.Value, @ptrCast(&.{}));
    const handle = v8.c.v8__Function__NewInstance(self.handle, ctx.v8_context.handle, 0, null) orelse {
        if (try_catch.hasCaught()) {
            const allocator = ctx.call_arena;
            result.stack = try_catch.stack(allocator) catch null;
            result.exception = (try_catch.exception(allocator) catch "???") orelse "???";
        } else {
            result.stack = null;
            result.exception = "???";
        }
        return error.JsConstructorFailed;
    };

    return .{
        .ctx = ctx,
        .handle = handle,
    };
}

pub fn call(self: *const Function, comptime T: type, args: anytype) !T {
    return self.callWithThis(T, self.getThis(), args);
}

pub fn tryCall(self: *const Function, comptime T: type, args: anytype, result: *Result) !T {
    return self.tryCallWithThis(T, self.getThis(), args, result);
}

pub fn tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, result: *Result) !T {
    var try_catch: js.TryCatch = undefined;

    try_catch.init(self.ctx);
    defer try_catch.deinit();

    return self.callWithThis(T, this, args) catch |err| {
        if (try_catch.hasCaught()) {
            const allocator = self.ctx.call_arena;
            result.stack = try_catch.stack(allocator) catch null;
            result.exception = (try_catch.exception(allocator) catch @errorName(err)) orelse @errorName(err);
        } else {
            result.stack = null;
            result.exception = @errorName(err);
        }
        return err;
    };
}

pub fn callWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype) !T {
    const ctx = self.ctx;

<<<<<<< HEAD
    // When we're calling a function from within JavaScript itself, this isn't
    // necessary. We're within a Caller instantiation, which will already have
    // incremented the call_depth and it won't decrement it until the Caller is
    // done.
    // But some JS functions are initiated from Zig code, and not v8. For
    // example, Observers, some event and window callbacks. In those cases, we
    // need to increase the call_depth so that the call_arena remains valid for
    // the duration of the function call. If we don't do this, the call_arena
    // will be reset after each statement of the function which executes Zig code.
    const call_depth = context.call_depth;
    context.call_depth = call_depth + 1;
    defer context.call_depth = call_depth;

    const js_this = blk: {
        if (@TypeOf(this) == v8.Object) {
            break :blk this;
        }

        if (@TypeOf(this) == js.Object) {
            break :blk this.js_obj;
        }
        break :blk try context.zigValueToJs(this, .{});
    };

    const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

    const js_args: []const v8.Value = switch (@typeInfo(@TypeOf(aargs))) {
        .@"struct" => |s| blk: {
            const fields = s.fields;
            var js_args: [fields.len]v8.Value = undefined;
            inline for (fields, 0..) |f, i| {
                js_args[i] = try ctx.zigValueToJs(@field(aargs, f.name), .{});
            }
            const cargs: [fields.len]v8.Value = js_args;
            break :blk &cargs;
        },
        .pointer => blk: {
            var values = try ctx.call_arena.alloc(v8.Value, args.len);
            for (args, 0..) |a, i| {
                values[i] = try ctx.zigValueToJs(a, .{});
            }
            break :blk values;
        },
        else => @compileError("JS Function called with invalid paremter type"),
    };

    const c_args = @as(?[*]const ?*v8.c.Value, @ptrCast(js_args.ptr));
    const handle = v8.c.v8__Function__Call(self.handle, ctx.v8_context.handle, js_this.handle, @as(c_int, @intCast(js_args.len)), c_args) orelse {
        // std.debug.print("CB ERR: {s}\n", .{self.src() catch "???"});
        return error.JSExecCallback;
    };

    if (@typeInfo(T) == .void) {
        return {};
    }
    return ctx.jsValueToZig(T, .{ .handle = handle });
}

fn getThis(self: *const Function) js.Object {
    const handle = self.this orelse self.ctx.v8_context.getGlobal().handle;
    return .{
        .ctx = self.ctx,
        .handle = handle,
    };
}

pub fn src(self: *const Function) ![]const u8 {
    return self.context.valueToString(.{ .handle = @ptrCast(self.handle) }, .{});
}

pub fn getPropertyValue(self: *const Function, name: []const u8) !?js.Value {
    const ctx = self.ctx;
    const key = v8.String.initUtf8(ctx.isolate, name);
    const handle = v8.c.v8__Object__Get(self.handle, ctx.v8_context.handle, key.handle) orelse {
        return error.JsException;
    };

    return .{
        .ctx = ctx,
        .handle = handle,
    };
}

pub fn persist(self: *const Function) !Function {
    var ctx = self.ctx;

    const global = js.Global(Function).init(ctx.isolate.handle, self.handle);
    try ctx.global_functions.append(ctx.arena, global);

    return .{
        .ctx = ctx,
        .this = self.this,
        .handle = global.local(),
    };
}

pub fn persistWithThis(self: *const Function, value: anytype) !Function {
    var persisted = try self.persist();
    return persisted.withThis(value);
}

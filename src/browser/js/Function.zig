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
this: ?*const v8.Object = null,
handle: *const v8.Function,

pub const Result = struct {
    stack: ?[]const u8,
    exception: []const u8,
};

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

pub fn newInstance(self: *const Function, caught: *js.TryCatch.Caught) !js.Object {
    const ctx = self.ctx;

    var try_catch: js.TryCatch = undefined;
    try_catch.init(ctx);
    defer try_catch.deinit();

    // This creates a new instance using this Function as a constructor.
    // const c_args = @as(?[*]const ?*c.Value, @ptrCast(&.{}));
    const handle = v8.v8__Function__NewInstance(self.handle, ctx.handle, 0, null) orelse {
        caught.* = try_catch.caughtOrError(ctx.call_arena, error.Unknown);
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

pub fn tryCall(self: *const Function, comptime T: type, args: anytype, caught: *js.TryCatch.Caught) !T {
    return self.tryCallWithThis(T, self.getThis(), args, caught);
}

pub fn tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, caught: *js.TryCatch.Caught) !T {
    var try_catch: js.TryCatch = undefined;

    try_catch.init(self.ctx);
    defer try_catch.deinit();

    return self.callWithThis(T, this, args) catch |err| {
        caught.* = try_catch.caughtOrError(self.ctx.call_arena, err);
        return err;
    };
}

pub fn callWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype) !T {
    const ctx = self.ctx;

    // When we're calling a function from within JavaScript itself, this isn't
    // necessary. We're within a Caller instantiation, which will already have
    // incremented the call_depth and it won't decrement it until the Caller is
    // done.
    // But some JS functions are initiated from Zig code, and not v8. For
    // example, Observers, some event and window callbacks. In those cases, we
    // need to increase the call_depth so that the call_arena remains valid for
    // the duration of the function call. If we don't do this, the call_arena
    // will be reset after each statement of the function which executes Zig code.
    const call_depth = ctx.call_depth;
    ctx.call_depth = call_depth + 1;
    defer ctx.call_depth = call_depth;

    const js_this = blk: {
        if (@TypeOf(this) == js.Object) {
            break :blk this;
        }
        break :blk try ctx.zigValueToJs(this, .{});
    };

    const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

    const js_args: []const *const v8.Value = switch (@typeInfo(@TypeOf(aargs))) {
        .@"struct" => |s| blk: {
            const fields = s.fields;
            var js_args: [fields.len]*const v8.Value = undefined;
            inline for (fields, 0..) |f, i| {
                js_args[i] = (try ctx.zigValueToJs(@field(aargs, f.name), .{})).handle;
            }
            const cargs: [fields.len]*const v8.Value = js_args;
            break :blk &cargs;
        },
        .pointer => blk: {
            var values = try ctx.call_arena.alloc(*const v8.Value, args.len);
            for (args, 0..) |a, i| {
                values[i] = (try ctx.zigValueToJs(a, .{})).handle;
            }
            break :blk values;
        },
        else => @compileError("JS Function called with invalid paremter type"),
    };

    const c_args = @as(?[*]const ?*v8.Value, @ptrCast(js_args.ptr));
    const handle = v8.v8__Function__Call(self.handle, ctx.handle, js_this.handle, @as(c_int, @intCast(js_args.len)), c_args) orelse {
        // std.debug.print("CB ERR: {s}\n", .{self.src() catch "???"});
        return error.JSExecCallback;
    };

    if (@typeInfo(T) == .void) {
        return {};
    }
    return ctx.jsValueToZig(T, .{ .ctx = ctx, .handle = handle });
}

fn getThis(self: *const Function) js.Object {
    const handle = if (self.this) |t| t else v8.v8__Context__Global(self.ctx.handle).?;
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
    const key = ctx.isolate.initStringHandle(name);
    const handle = v8.v8__Object__Get(self.handle, ctx.handle, key) orelse {
        return error.JsException;
    };

    return .{
        .ctx = ctx,
        .handle = handle,
    };
}

pub fn persist(self: *const Function) !Global {
    var ctx = self.ctx;

    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);

    try ctx.global_functions.append(ctx.arena, global);

    return .{
        .handle = global,
        .ctx = ctx,
    };
}

pub fn persistWithThis(self: *const Function, value: anytype) !Global {
    const with_this = try self.withThis(value);
    return with_this.persist();
}

pub const Global = struct {
    handle: v8.Global,
    ctx: *js.Context,

    pub fn deinit(self: *Global) void {
        v8.v8__Global__Reset(&self.handle);
    }

    pub fn local(self: *const Global) Function {
        return .{
            .ctx = self.ctx,
            .handle = @ptrCast(v8.v8__Global__Get(&self.handle, self.ctx.isolate.handle)),
        };
    }

    pub fn isEqual(self: *const Global, other: Function) bool {
        return v8.v8__Global__IsEqual(&self.handle, other.handle);
    }
};

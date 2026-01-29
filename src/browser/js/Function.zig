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
const js = @import("js.zig");
const v8 = js.v8;

const log = @import("../../log.zig");

const Function = @This();

local: *const js.Local,
this: ?*const v8.Object = null,
handle: *const v8.Function,

pub const Result = struct {
    stack: ?[]const u8,
    exception: []const u8,
};

pub fn withThis(self: *const Function, value: anytype) !Function {
    const local = self.local;
    const this_obj = if (@TypeOf(value) == js.Object)
        value.handle
    else
        (try local.zigValueToJs(value, .{})).handle;

    return .{
        .local = local,
        .this = this_obj,
        .handle = self.handle,
    };
}

pub fn newInstance(self: *const Function, caught: *js.TryCatch.Caught) !js.Object {
    const local = self.local;

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    // This creates a new instance using this Function as a constructor.
    // const c_args = @as(?[*]const ?*c.Value, @ptrCast(&.{}));
    const handle = v8.v8__Function__NewInstance(self.handle, local.handle, 0, null) orelse {
        caught.* = try_catch.caughtOrError(local.call_arena, error.Unknown);
        return error.JsConstructorFailed;
    };

    return .{
        .local = local,
        .handle = handle,
    };
}

pub fn call(self: *const Function, comptime T: type, args: anytype) !T {
    var caught: js.TryCatch.Caught = undefined;
    return self._tryCallWithThis(T, self.getThis(), args, &caught) catch |err| {
        log.warn(.js, "call caught", .{ .err = err, .caught = caught });
        return err;
    };
}

pub fn callWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype) !T {
    var caught: js.TryCatch.Caught = undefined;
    return self._tryCallWithThis(T, this, args, &caught) catch |err| {
        log.warn(.js, "callWithThis caught", .{ .err = err, .caught = caught });
        return err;
    };
}

pub fn tryCall(self: *const Function, comptime T: type, args: anytype, caught: *js.TryCatch.Caught) !T {
    return self._tryCallWithThis(T, self.getThis(), args, caught);
}

pub fn tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, caught: *js.TryCatch.Caught) !T {
    return self._tryCallWithThis(T, this, args, caught);
}

pub fn _tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, caught: *js.TryCatch.Caught) !T {
    caught.* = .{};
    const local = self.local;

    // When we're calling a function from within JavaScript itself, this isn't
    // necessary. We're within a Caller instantiation, which will already have
    // incremented the call_depth and it won't decrement it until the Caller is
    // done.
    // But some JS functions are initiated from Zig code, and not v8. For
    // example, Observers, some event and window callbacks. In those cases, we
    // need to increase the call_depth so that the call_arena remains valid for
    // the duration of the function call. If we don't do this, the call_arena
    // will be reset after each statement of the function which executes Zig code.
    const ctx = local.ctx;
    const call_depth = ctx.call_depth;
    ctx.call_depth = call_depth + 1;
    defer ctx.call_depth = call_depth;

    const js_this = blk: {
        if (@TypeOf(this) == js.Object) {
            break :blk this;
        }
        break :blk try local.zigValueToJs(this, .{});
    };

    const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

    const js_args: []const *const v8.Value = switch (@typeInfo(@TypeOf(aargs))) {
        .@"struct" => |s| blk: {
            const fields = s.fields;
            var js_args: [fields.len]*const v8.Value = undefined;
            inline for (fields, 0..) |f, i| {
                js_args[i] = (try local.zigValueToJs(@field(aargs, f.name), .{})).handle;
            }
            const cargs: [fields.len]*const v8.Value = js_args;
            break :blk &cargs;
        },
        .pointer => blk: {
            var values = try local.call_arena.alloc(*const v8.Value, args.len);
            for (args, 0..) |a, i| {
                values[i] = (try local.zigValueToJs(a, .{})).handle;
            }
            break :blk values;
        },
        else => @compileError("JS Function called with invalid paremter type"),
    };

    const c_args = @as(?[*]const ?*v8.Value, @ptrCast(js_args.ptr));

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const handle = v8.v8__Function__Call(self.handle, local.handle, js_this.handle, @as(c_int, @intCast(js_args.len)), c_args) orelse {
        caught.* = try_catch.caughtOrError(local.call_arena, error.JSExecCallback);
        return error.JSExecCallback;
    };

    if (@typeInfo(T) == .void) {
        return {};
    }
    return local.jsValueToZig(T, .{ .local = local, .handle = handle });
}

fn getThis(self: *const Function) js.Object {
    const handle = if (self.this) |t| t else v8.v8__Context__Global(self.local.handle).?;
    return .{
        .local = self.local,
        .handle = handle,
    };
}

pub fn src(self: *const Function) ![]const u8 {
    return self.local.valueToString(.{ .local = self.local, .handle = @ptrCast(self.handle) }, .{});
}

pub fn getPropertyValue(self: *const Function, name: []const u8) !?js.Value {
    const local = self.local;
    const key = local.isolate.initStringHandle(name);
    const handle = v8.v8__Object__Get(self.handle, self.local.handle, key) orelse {
        return error.JsException;
    };

    return .{
        .local = local,
        .handle = handle,
    };
}

pub fn persist(self: *const Function) !Global {
    return self._persist(true);
}

pub fn temp(self: *const Function) !Temp {
    return self._persist(false);
}

fn _persist(self: *const Function, comptime is_global: bool) !(if (is_global) Global else Temp) {
    var ctx = self.local.ctx;

    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    if (comptime is_global) {
        try ctx.global_functions.append(ctx.arena, global);
    } else {
        try ctx.global_functions_temp.put(ctx.arena, global.data_ptr, global);
    }
    return .{ .handle = global };
}

pub fn tempWithThis(self: *const Function, value: anytype) !Temp {
    const with_this = try self.withThis(value);
    return with_this.temp();
}

pub fn persistWithThis(self: *const Function, value: anytype) !Global {
    const with_this = try self.withThis(value);
    return with_this.persist();
}

pub const Temp = G(0);
pub const Global = G(1);

fn G(comptime discriminator: u8) type {
    return struct {
        handle: v8.Global,

        // makes the types different (G(0) != G(1)), without taking up space
        comptime _: u8 = discriminator,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            v8.v8__Global__Reset(&self.handle);
        }

        pub fn local(self: *const Self, l: *const js.Local) Function {
            return .{
                .local = l,
                .handle = @ptrCast(v8.v8__Global__Get(&self.handle, l.isolate.handle)),
            };
        }

        pub fn isEqual(self: *const Self, other: Function) bool {
            return v8.v8__Global__IsEqual(&self.handle, other.handle);
        }
    };
}

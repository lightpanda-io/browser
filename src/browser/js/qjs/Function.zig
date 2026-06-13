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

const js = @import("js.zig");

const q = js.q;
const log = lp.log;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Function = @This();

local: *const js.Local,
this: ?q.JSValue = null,
handle: q.JSValue,

pub const Result = struct {
    stack: ?[]const u8,
    exception: []const u8,
};

fn qctx(self: *const Function) *q.JSContext {
    return self.local.ctx.ctx;
}

pub fn withThis(self: *const Function, value: anytype) !Function {
    const local = self.local;
    const this_handle = if (@TypeOf(value) == js.Object)
        value.handle
    else
        (try local.zigValueToJs(value, .{})).handle;

    return .{
        .local = local,
        .this = this_handle,
        .handle = self.handle,
    };
}

pub fn newInstance(self: *const Function, caught: *js.TryCatch.Caught) !js.Object {
    const local = self.local;

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const handle = q.JS_CallConstructor(self.qctx(), self.handle, 0, null);
    if (q.JS_IsException(handle)) {
        caught.* = try_catch.caughtOrError(local.call_arena, error.Unknown);
        return error.JsConstructorFailed;
    }
    local.track(handle);

    return .{
        .local = local,
        .handle = handle,
    };
}

pub fn call(self: *const Function, comptime T: type, args: anytype) !T {
    var caught: js.TryCatch.Caught = undefined;
    return self._tryCallWithThis(T, self.getThis(), args, &caught, .{}) catch |err| {
        log.warn(.js, "call caught", .{ .err = err, .caught = caught });
        return err;
    };
}

pub fn callRethrow(self: *const Function, comptime T: type, args: anytype) !T {
    var caught: js.TryCatch.Caught = undefined;
    return self._tryCallWithThis(T, self.getThis(), args, &caught, .{ .rethrow = true }) catch |err| {
        log.warn(.js, "call caught", .{ .err = err, .caught = caught });
        return err;
    };
}

pub fn callWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype) !T {
    var caught: js.TryCatch.Caught = undefined;
    return self._tryCallWithThis(T, this, args, &caught, .{}) catch |err| {
        log.warn(.js, "callWithThis caught", .{ .err = err, .caught = caught });
        return err;
    };
}

pub fn tryCall(self: *const Function, comptime T: type, args: anytype, caught: *js.TryCatch.Caught) !T {
    return self._tryCallWithThis(T, self.getThis(), args, caught, .{});
}

pub fn tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, caught: *js.TryCatch.Caught) !T {
    return self._tryCallWithThis(T, this, args, caught, .{});
}

const CallOpts = struct {
    rethrow: bool = false,
};

fn _tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, caught: *js.TryCatch.Caught, comptime opts: CallOpts) !T {
    caught.* = .{};
    const local = self.local;
    const ctx_ = self.qctx();

    // See v8/Function.zig: keep the call_arena alive for the duration of
    // Zig-initiated JS calls.
    const ctx = local.ctx;
    const call_depth = ctx.call_depth;
    ctx.call_depth = call_depth + 1;
    defer ctx.call_depth = call_depth;

    const js_this = blk: {
        if (@TypeOf(this) == js.Object) {
            break :blk this;
        }
        break :blk (try local.zigValueToJs(this, .{})).toObject();
    };

    const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

    const js_args: []const q.JSValue = switch (@typeInfo(@TypeOf(aargs))) {
        .@"struct" => |s| blk: {
            const fields = s.fields;
            var values = try local.call_arena.alloc(q.JSValue, fields.len);
            inline for (fields, 0..) |f, i| {
                values[i] = (try local.zigValueToJs(@field(aargs, f.name), .{})).handle;
            }
            break :blk values;
        },
        .pointer => blk: {
            var values = try local.call_arena.alloc(q.JSValue, args.len);
            for (args, 0..) |a, i| {
                values[i] = (try local.zigValueToJs(a, .{})).handle;
            }
            break :blk values;
        },
        else => @compileError("JS Function called with invalid parameter type"),
    };

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const handle = q.JS_Call(ctx_, self.handle, js_this.handle, @intCast(js_args.len), @constCast(js_args.ptr));
    if (q.JS_IsException(handle)) {
        if ((comptime opts.rethrow) and try_catch.hasCaught()) {
            try_catch.rethrow();
            return error.TryCatchRethrow;
        }
        caught.* = try_catch.caughtOrError(local.call_arena, error.JsException);
        return error.JsException;
    }
    local.track(handle);

    if (@typeInfo(T) == .void) {
        return {};
    }
    return local.jsValueToZig(T, .{ .local = local, .handle = handle });
}

fn getThis(self: *const Function) js.Object {
    if (self.this) |t| {
        return .{ .local = self.local, .handle = t };
    }
    return self.local.getGlobal();
}

pub fn src(self: *const Function) ![]const u8 {
    return js.Value.toStringSlice(.{ .local = self.local, .handle = self.handle });
}

pub fn getPropertyValue(self: *const Function, name: [:0]const u8) !?js.Value {
    const obj = js.Object{ .local = self.local, .handle = self.handle };
    return try obj.get(name);
}

pub fn persist(self: *const Function) !Global {
    return self._persist(true);
}

pub fn temp(self: *const Function) !Temp {
    return self._persist(false);
}

fn _persist(self: *const Function, comptime is_global: bool) !(if (is_global) Global else Temp) {
    var ctx = self.local.ctx;
    const handle = ctx.persist(q.JS_DupValue(ctx.ctx, self.handle));
    if (comptime is_global) {
        try ctx.trackGlobal(handle);
        return .{ .handle = handle, .temps = {} };
    }
    try ctx.trackTemp(handle);
    return .{ .handle = handle, .temps = &ctx.page.temps };
}

pub fn tempWithThis(self: *const Function, value: anytype) !Temp {
    const with_this = try self.withThis(value);
    return with_this.temp();
}

pub fn persistWithThis(self: *const Function, value: anytype) !Global {
    const with_this = try self.withThis(value);
    return with_this.persist();
}

pub const Temp = G(.temp);
pub const Global = G(.global);

const GlobalType = enum(u8) {
    temp,
    global,
};

fn G(comptime global_type: GlobalType) type {
    return struct {
        handle: js.PersistentHandle,
        temps: if (global_type == .temp) *std.AutoHashMapUnmanaged(usize, js.PersistentHandle) else void,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            js.resetPersistentHandle(&self.handle);
        }

        pub fn local(self: *const Self, l: *const js.Local) Function {
            return .{
                .local = l,
                .handle = self.handle.value,
            };
        }

        pub fn isEqual(self: *const Self, other: Function) bool {
            return q.JS_IsSameValue(other.local.ctx.ctx, self.handle.value, other.handle);
        }

        pub fn release(self: *const Self) void {
            if (self.temps.fetchRemove(self.handle.key)) |kv| {
                var g = kv.value;
                js.resetPersistentHandle(&g);
            }
        }
    };
}

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

const PersistentFunction = v8.Persistent(v8.Function);

const Allocator = std.mem.Allocator;

const Function = @This();

id: usize,
context: *js.Context,
this: ?v8.Object = null,
func: PersistentFunction,

pub const Result = struct {
    stack: ?[]const u8,
    exception: []const u8,
};

pub fn getName(self: *const Function, allocator: Allocator) ![]const u8 {
    const name = self.func.castToFunction().getName();
    return self.context.valueToString(name, .{ .allocator = allocator });
}

pub fn setName(self: *const Function, name: []const u8) void {
    const v8_name = v8.String.initUtf8(self.context.isolate, name);
    self.func.castToFunction().setName(v8_name);
}

pub fn withThis(self: *const Function, value: anytype) !Function {
    const this_obj = if (@TypeOf(value) == js.Object)
        value.js_obj
    else
        (try self.context.zigValueToJs(value, .{})).castTo(v8.Object);

    return .{
        .id = self.id,
        .this = this_obj,
        .func = self.func,
        .context = self.context,
    };
}

pub fn newInstance(self: *const Function, result: *Result) !js.Object {
    const context = self.context;

    var try_catch: js.TryCatch = undefined;
    try_catch.init(context);
    defer try_catch.deinit();

    // This creates a new instance using this Function as a constructor.
    // This returns a generic Object
    const js_obj = self.func.castToFunction().initInstance(context.v8_context, &.{}) orelse {
        if (try_catch.hasCaught()) {
            const allocator = context.call_arena;
            result.stack = try_catch.stack(allocator) catch null;
            result.exception = (try_catch.exception(allocator) catch "???") orelse "???";
        } else {
            result.stack = null;
            result.exception = "???";
        }
        return error.JsConstructorFailed;
    };

    return .{
        .context = context,
        .js_obj = js_obj,
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
    try_catch.init(self.context);
    defer try_catch.deinit();

    return self.callWithThis(T, this, args) catch |err| {
        if (try_catch.hasCaught()) {
            const allocator = self.context.call_arena;
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
    const context = self.context;

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

    const js_this = try context.valueToExistingObject(this);

    const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

    const js_args: []const v8.Value = switch (@typeInfo(@TypeOf(aargs))) {
        .@"struct" => |s| blk: {
            const fields = s.fields;
            var js_args: [fields.len]v8.Value = undefined;
            inline for (fields, 0..) |f, i| {
                js_args[i] = try context.zigValueToJs(@field(aargs, f.name), .{});
            }
            const cargs: [fields.len]v8.Value = js_args;
            break :blk &cargs;
        },
        .pointer => blk: {
            var values = try context.call_arena.alloc(v8.Value, args.len);
            for (args, 0..) |a, i| {
                values[i] = try context.zigValueToJs(a, .{});
            }
            break :blk values;
        },
        else => @compileError("JS Function called with invalid paremter type"),
    };

    const result = self.func.castToFunction().call(context.v8_context, js_this, js_args);
    if (result == null) {
        // std.debug.print("CB ERR: {s}\n", .{self.src() catch "???"});
        return error.JSExecCallback;
    }

    if (@typeInfo(T) == .void) return {};
    return context.jsValueToZig(T, result.?);
}

fn getThis(self: *const Function) v8.Object {
    return self.this orelse self.context.v8_context.getGlobal();
}

pub fn src(self: *const Function) ![]const u8 {
    const value = self.func.castToFunction().toValue();
    return self.context.valueToString(value, .{});
}

pub fn getPropertyValue(self: *const Function, name: []const u8) !?js.Value {
    const func_obj = self.func.castToFunction().toObject();
    const key = v8.String.initUtf8(self.context.isolate, name);
    const value = func_obj.getValue(self.context.v8_context, key) catch return null;
    return self.context.createValue(value);
}

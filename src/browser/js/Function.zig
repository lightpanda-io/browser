const std = @import("std");
const js = @import("js.zig");
const v8 = js.v8;

const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
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
        (try self.context.zigValueToJs(value)).castTo(v8.Object);

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

    const js_this = try context.valueToExistingObject(this);

    const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

    const js_args: []const v8.Value = switch (@typeInfo(@TypeOf(aargs))) {
        .@"struct" => |s| blk: {
            const fields = s.fields;
            var js_args: [fields.len]v8.Value = undefined;
            inline for (fields, 0..) |f, i| {
                js_args[i] = try context.zigValueToJs(@field(aargs, f.name));
            }
            const cargs: [fields.len]v8.Value = js_args;
            break :blk &cargs;
        },
        .pointer => blk: {
            var values = try context.call_arena.alloc(v8.Value, args.len);
            for (args, 0..) |a, i| {
                values[i] = try context.zigValueToJs(a);
            }
            break :blk values;
        },
        else => @compileError("JS Function called with invalid paremter type"),
    };

    const result = self.func.castToFunction().call(context.v8_context, js_this, js_args);
    if (result == null) {
        return error.JSExecCallback;
    }

    if (@typeInfo(T) == .void) return {};
    const named_function = comptime Caller.NamedFunction.init(T, "callResult");
    return context.jsValueToZig(named_function, T, result.?);
}

fn getThis(self: *const Function) v8.Object {
    return self.this orelse self.context.v8_context.getGlobal();
}

// debug/helper to print the source of the JS callback
pub fn printFunc(self: Function) !void {
    const context = self.context;
    const value = self.func.castToFunction().toValue();
    const src = try js.valueToString(context.call_arena, value, context.isolate, context.v8_context);
    std.debug.print("{s}\n", .{src});
}

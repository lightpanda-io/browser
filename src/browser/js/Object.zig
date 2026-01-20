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

const IS_DEBUG = @import("builtin").mode == .Debug;

const Context = @import("Context.zig");

const Allocator = std.mem.Allocator;

const Object = @This();

local: *const js.Local,
handle: *const v8.Object,

pub fn getId(self: Object) u32 {
    return @bitCast(v8.v8__Object__GetIdentityHash(self.handle));
}

pub fn has(self: Object, key: anytype) bool {
    const ctx = self.local.ctx;
    const key_handle = if (@TypeOf(key) == *const v8.String) key else ctx.isolate.initStringHandle(key);

    var out: v8.MaybeBool = undefined;
    v8.v8__Object__Has(self.handle, self.local.handle, key_handle, &out);
    if (out.has_value) {
        return out.value;
    }
    return false;
}

pub fn get(self: Object, key: anytype) !js.Value {
    const ctx = self.local.ctx;

    const key_handle = if (@TypeOf(key) == *const v8.String) key else ctx.isolate.initStringHandle(key);
    const js_val_handle = v8.v8__Object__Get(self.handle, self.local.handle, key_handle) orelse return error.JsException;

    return .{
        .local = self.local,
        .handle = js_val_handle,
    };
}

pub fn set(self: Object, key: anytype, value: anytype, comptime opts: js.Caller.CallOpts) !bool {
    const ctx = self.local.ctx;

    const js_value = try self.local.zigValueToJs(value, opts);
    const key_handle = if (@TypeOf(key) == *const v8.String) key else ctx.isolate.initStringHandle(key);

    var out: v8.MaybeBool = undefined;
    v8.v8__Object__Set(self.handle, self.local.handle, key_handle, js_value.handle, &out);
    return out.has_value;
}

pub fn defineOwnProperty(self: Object, name: []const u8, value: js.Value, attr: v8.PropertyAttribute) ?bool {
    const ctx = self.local.ctx;
    const name_handle = ctx.isolate.initStringHandle(name);

    var out: v8.MaybeBool = undefined;
    v8.v8__Object__DefineOwnProperty(self.handle, self.local.handle, @ptrCast(name_handle), value.handle, attr, &out);

    if (out.has_value) {
        return out.value;
    } else {
        return null;
    }
}

pub fn toString(self: Object) ![]const u8 {
    return self.local.ctx.valueToString(self.toValue(), .{});
}

pub fn toValue(self: Object) js.Value {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn format(self: Object, writer: *std.Io.Writer) !void {
    if (comptime IS_DEBUG) {
        return self.local.ctx.debugValue(self.toValue(), writer);
    }
    const str = self.toString() catch return error.WriteFailed;
    return writer.writeAll(str);
}

pub fn persist(self: Object) !Global {
    var ctx = self.local.ctx;

    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);

    try ctx.global_objects.append(ctx.arena, global);

    return .{ .handle = global };
}

pub fn getFunction(self: Object, name: []const u8) !?js.Function {
    if (self.isNullOrUndefined()) {
        return null;
    }
    const local = self.local;

    const js_name = local.isolate.initStringHandle(name);
    const js_val_handle = v8.v8__Object__Get(self.handle, local.handle, js_name) orelse return error.JsException;

    if (v8.v8__Value__IsFunction(js_val_handle) == false) {
        return null;
    }
    return .{
        .local = local,
        .handle = @ptrCast(js_val_handle),
    };
}

pub fn callMethod(self: Object, comptime T: type, method_name: []const u8, args: anytype) !T {
    const func = try self.getFunction(method_name) orelse return error.MethodNotFound;
    return func.callWithThis(T, self, args);
}

pub fn isNullOrUndefined(self: Object) bool {
    return v8.v8__Value__IsNullOrUndefined(@ptrCast(self.handle));
}

pub fn getOwnPropertyNames(self: Object) js.Array {
    const handle = v8.v8__Object__GetOwnPropertyNames(self.handle, self.local.handle).?;
    return .{
        .local = self.local,
        .handle = handle,
    };
}

pub fn getPropertyNames(self: Object) js.Array {
    const handle = v8.v8__Object__GetPropertyNames(self.handle, self.local.handle).?;
    return .{
        .local = self.local,
        .handle = handle,
    };
}

pub fn nameIterator(self: Object) NameIterator {
    const handle = v8.v8__Object__GetPropertyNames(self.handle, self.local.handle).?;
    const count = v8.v8__Array__Length(handle);

    return .{
        .local = self.local,
        .handle = handle,
        .count = count,
    };
}

pub fn toZig(self: Object, comptime T: type) !T {
    const js_value = js.Value{ .local = self.local, .handle = @ptrCast(self.handle) };
    return self.local.jsValueToZig(T, js_value);
}

pub const Global = struct {
    handle: v8.Global,

    pub fn deinit(self: *Global) void {
        v8.v8__Global__Reset(&self.handle);
    }

    pub fn local(self: *const Global, l: *const js.Local) Object {
        return .{
            .local = l,
            .handle = @ptrCast(v8.v8__Global__Get(&self.handle, l.isolate.handle)),
        };
    }

    pub fn isEqual(self: *const Global, other: Object) bool {
        return v8.v8__Global__IsEqual(&self.handle, other.handle);
    }
};

pub const NameIterator = struct {
    count: u32,
    idx: u32 = 0,
    local: *const js.Local,
    handle: *const v8.Array,

    pub fn next(self: *NameIterator) !?[]const u8 {
        const idx = self.idx;
        if (idx == self.count) {
            return null;
        }
        self.idx += 1;

        const js_val_handle = v8.v8__Object__GetIndex(@ptrCast(self.handle), self.local.handle, idx) orelse return error.JsException;
        const js_val = js.Value{ .local = self.local, .handle = js_val_handle };
        return try self.local.valueToString(js_val, .{});
    }
};

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

const q = js.q;
const Allocator = std.mem.Allocator;

const Object = @This();

local: *const js.Local,
handle: q.JSValue,

fn qctx(self: Object) *q.JSContext {
    return self.local.ctx.ctx;
}

pub fn has(self: Object, key: anytype) bool {
    const ctx = self.qctx();
    const k = keyZ(key) catch return false;
    const atom = q.JS_NewAtomLen(ctx, k.ptr, k.len);
    defer q.JS_FreeAtom(ctx, atom);
    return q.JS_HasProperty(ctx, self.handle, atom) == 1;
}

pub fn get(self: Object, key: anytype) !js.Value {
    const ctx = self.qctx();
    const k = try keyZ(key);
    const value = q.JS_GetPropertyStr(ctx, self.handle, k.ptr);
    if (q.JS_IsException(value)) {
        return error.JsException;
    }
    self.local.track(value);
    return .{ .local = self.local, .handle = value };
}

pub fn set(self: Object, key: anytype, value: anytype, comptime opts: js.Caller.CallOpts) !bool {
    const ctx = self.qctx();
    const js_value = try self.local.zigValueToJs(value, opts);
    const k = try keyZ(key);
    // JS_SetPropertyStr consumes a reference; ours stays on the handle stack.
    const ret = q.JS_SetPropertyStr(ctx, self.handle, k.ptr, q.JS_DupValue(ctx, js_value.handle));
    if (ret < 0) {
        return error.JsException;
    }
    return ret == 1;
}

pub fn defineOwnProperty(self: Object, name: [:0]const u8, value: js.Value, attr: u32) ?bool {
    _ = attr;
    const ctx = self.qctx();
    const ret = q.JS_DefinePropertyValueStr(ctx, self.handle, name.ptr, q.JS_DupValue(ctx, value.handle), q.JS_PROP_C_W_E);
    if (ret < 0) {
        return null;
    }
    return ret == 1;
}

pub fn toValue(self: Object) js.Value {
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn format(self: Object, writer: *std.Io.Writer) !void {
    return self.toValue().format(writer);
}

pub fn persist(self: Object) !Global {
    var ctx = self.local.ctx;
    const handle = ctx.persist(q.JS_DupValue(ctx.ctx, self.handle));
    try ctx.trackGlobal(handle);
    return .{ .handle = handle };
}

pub fn getFunction(self: Object, name: [:0]const u8) !?js.Function {
    if (!self.isNullOrUndefined()) {
        const value = try self.get(name);
        if (value.isFunction()) {
            return js.Function{ .local = self.local, .handle = value.handle };
        }
    }
    return null;
}

pub fn callMethod(self: Object, comptime T: type, method_name: [:0]const u8, args: anytype) !T {
    const func = (try self.getFunction(method_name)) orelse return error.MethodNotFound;
    return func.callWithThis(T, self, args);
}

pub fn isNullOrUndefined(self: Object) bool {
    return q.JS_IsNull(self.handle) or q.JS_IsUndefined(self.handle);
}

pub fn getOwnPropertyNames(self: Object) !js.Array {
    return self._propertyNames(q.JS_GPN_STRING_MASK | q.JS_GPN_ENUM_ONLY);
}

pub fn getPropertyNames(self: Object) js.Array {
    return self._propertyNames(q.JS_GPN_STRING_MASK) catch {
        return self.local.newArray(0);
    };
}

fn _propertyNames(self: Object, flags: c_int) !js.Array {
    const ctx = self.qctx();
    var ptab: [*c]q.JSPropertyEnum = null;
    var plen: u32 = 0;
    if (q.JS_GetOwnPropertyNames(ctx, &ptab, &plen, self.handle, flags) != 0) {
        return error.JsException;
    }
    defer q.JS_FreePropertyEnum(ctx, ptab, plen);

    const arr = self.local.newArray(plen);
    for (0..plen) |i| {
        const name = q.JS_AtomToString(ctx, ptab[i].atom);
        if (q.JS_IsException(name)) {
            return error.JsException;
        }
        // JS_SetPropertyUint32 consumes the reference
        if (q.JS_SetPropertyUint32(ctx, arr.handle, @intCast(i), name) < 0) {
            return error.JsException;
        }
    }
    return arr;
}

pub fn nameIterator(self: Object) !NameIterator {
    const names = try self.getOwnPropertyNames();
    return .{
        .names = names,
        .count = names.len(),
    };
}

pub fn toZig(self: Object, comptime T: type) !T {
    return self.local.jsValueToZig(T, self.toValue());
}

fn keyZ(key: anytype) ![:0]const u8 {
    const T = @TypeOf(key);
    if (T == js.String) {
        return key.toSliceZ();
    }
    if (T == js.Value) {
        return key.toStringSliceZ();
    }
    return key;
}

pub const Global = struct {
    handle: js.PersistentHandle,

    pub fn deinit(self: *Global) void {
        js.resetPersistentHandle(&self.handle);
    }

    pub fn local(self: *const Global, l: *const js.Local) Object {
        return .{ .local = l, .handle = self.handle.value };
    }

    pub fn isEqual(self: *const Global, other: Object) bool {
        return q.JS_IsSameValue(other.local.ctx.ctx, self.handle.value, other.handle);
    }
};

pub const NameIterator = struct {
    names: js.Array,
    count: usize,
    idx: u32 = 0,

    pub fn next(self: *NameIterator) !?[:0]const u8 {
        if (self.idx >= self.count) {
            return null;
        }
        const value = try self.names.get(self.idx);
        self.idx += 1;
        return try value.toStringSliceZ();
    }
};

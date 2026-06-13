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

const Promise = @This();

local: *const js.Local,
handle: q.JSValue,

pub fn toObject(self: Promise) js.Object {
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn toValue(self: Promise) js.Value {
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn thenAndCatch(self: Promise, on_fulfilled: js.Function, on_rejected: js.Function) !Promise {
    const ctx = self.local.ctx.ctx;
    const then_fn = q.JS_GetPropertyStr(ctx, self.handle, "then");
    self.local.track(then_fn);
    if (!q.JS_IsFunction(ctx, then_fn)) {
        return error.JsException;
    }

    var args = [_]q.JSValue{ on_fulfilled.handle, on_rejected.handle };
    const ret = q.JS_Call(ctx, then_fn, self.handle, args.len, &args);
    if (q.JS_IsException(ret)) {
        return error.JsException;
    }
    self.local.track(ret);
    return .{ .local = self.local, .handle = ret };
}

pub fn persist(self: Promise) !Global {
    return self._persist(true);
}

pub fn temp(self: Promise) !Temp {
    return self._persist(false);
}

fn _persist(self: *const Promise, comptime is_global: bool) !(if (is_global) Global else Temp) {
    var ctx = self.local.ctx;
    const handle = ctx.persist(q.JS_DupValue(ctx.ctx, self.handle));
    if (comptime is_global) {
        try ctx.trackGlobal(handle);
        return .{ .handle = handle, .temps = {} };
    }
    try ctx.trackTemp(handle);
    return .{ .handle = handle, .temps = &ctx.page.temps };
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

        pub fn local(self: *const Self, l: *const js.Local) Promise {
            return .{
                .local = l,
                .handle = self.handle.value,
            };
        }

        pub fn release(self: *const Self) void {
            if (self.temps.fetchRemove(self.handle.key)) |kv| {
                var g = kv.value;
                js.resetPersistentHandle(&g);
            }
        }
    };
}

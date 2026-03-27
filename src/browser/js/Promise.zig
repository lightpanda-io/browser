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

const Promise = @This();

local: *const js.Local,
handle: *const v8.Promise,

pub fn toObject(self: Promise) js.Object {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toValue(self: Promise) js.Value {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn thenAndCatch(self: Promise, on_fulfilled: js.Function, on_rejected: js.Function) !Promise {
    if (v8.v8__Promise__Then2(self.handle, self.local.handle, on_fulfilled.handle, on_rejected.handle)) |handle| {
        return .{
            .local = self.local,
            .handle = handle,
        };
    }
    return error.PromiseChainFailed;
}

pub fn persist(self: Promise) !Global {
    return self._persist(true);
}

pub fn temp(self: Promise) !Temp {
    return self._persist(false);
}

fn _persist(self: *const Promise, comptime is_global: bool) !(if (is_global) Global else Temp) {
    var ctx = self.local.ctx;

    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    if (comptime is_global) {
        try ctx.trackGlobal(global);
        return .{ .handle = global, .temps = {} };
    }
    try ctx.trackTemp(global);
    return .{ .handle = global, .temps = &ctx.identity.temps };
}

pub const Temp = G(.temp);
pub const Global = G(.global);

const GlobalType = enum(u8) {
    temp,
    global,
};

fn G(comptime global_type: GlobalType) type {
    return struct {
        handle: v8.Global,
        temps: if (global_type == .temp) *std.AutoHashMapUnmanaged(usize, v8.Global) else void,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            v8.v8__Global__Reset(&self.handle);
        }

        pub fn local(self: *const Self, l: *const js.Local) Promise {
            return .{
                .local = l,
                .handle = @ptrCast(v8.v8__Global__Get(&self.handle, l.isolate.handle)),
            };
        }

        pub fn release(self: *const Self) void {
            if (self.temps.fetchRemove(self.handle.data_ptr)) |kv| {
                var g = kv.value;
                v8.v8__Global__Reset(&g);
            }
        }
    };
}

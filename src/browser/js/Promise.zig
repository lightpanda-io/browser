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
    var ctx = self.local.ctx;
    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    try ctx.global_promises.append(ctx.arena, global);
    return .{ .handle = global };
}

pub const Global = struct {
    handle: v8.Global,

    pub fn deinit(self: *Global) void {
        v8.v8__Global__Reset(&self.handle);
    }

    pub fn local(self: *const Global, l: *const js.Local) Promise {
        return .{
            .local = l,
            .handle = @ptrCast(v8.v8__Global__Get(&self.handle, l.isolate.handle)),
        };
    }
};

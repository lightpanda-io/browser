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

ctx: *js.Context,
handle: *const v8.c.Promise,

pub fn toObject(self: Promise) js.Object {
    return .{
        .ctx = self.ctx,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toValue(self: Promise) js.Value {
    return .{
        .ctx = self.ctx,
        .handle = @ptrCast(self.handle),
    };
}

pub fn thenAndCatch(self: Promise, on_fulfilled: js.Function, on_rejected: js.Function) !Promise {
    if (v8.c.v8__Promise__Then2(self.handle, self.ctx.handle, on_fulfilled.handle, on_rejected.handle)) |handle| {
        return .{
            .ctx = self.ctx,
            .handle = handle,
        };
    }
    return error.PromiseChainFailed;
}
pub fn persist(self: Promise) !Promise {
    var ctx = self.ctx;

    const global = js.Global(Promise).init(ctx.isolate.handle, self.handle);
    try ctx.global_promises.append(ctx.arena, global);

    return .{
        .ctx = ctx,
        .handle = global.local(),
    };
}

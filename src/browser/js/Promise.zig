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

handle: *const v8.c.Promise,

pub fn toObject(self: Promise) js.Object {
    return .{
        .ctx = undefined, // Will be set by caller if needed
        .handle = @ptrCast(self.handle),
    };
}

pub fn toValue(self: Promise) js.Value {
    return .{
        .ctx = undefined, // Will be set by caller if needed
        .handle = @ptrCast(self.handle),
    };
}

pub fn thenAndCatch(self: Promise, ctx_handle: *const v8.c.Context, on_fulfilled: js.Function, on_rejected: js.Function) !Promise {
    const v8_context = v8.Context{ .handle = ctx_handle };
    const v8_on_fulfilled = v8.Function{ .handle = on_fulfilled.handle };
    const v8_on_rejected = v8.Function{ .handle = on_rejected.handle };

    if (v8.c.v8__Promise__Then2(self.handle, v8_context.handle, v8_on_fulfilled.handle, v8_on_rejected.handle)) |handle| {
        return Promise{ .handle = handle };
    }
    return error.PromiseChainFailed;
}

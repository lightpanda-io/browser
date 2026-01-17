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

const Allocator = std.mem.Allocator;

const v8 = js.v8;

const String = @This();

local: *const js.Local,
handle: *const v8.String,

pub const ToZigOpts = struct {
    allocator: ?Allocator = null,
};

pub fn toZig(self: String, opts: ToZigOpts) ![]u8 {
    return self._toZig(false, opts);
}

pub fn toZigZ(self: String, opts: ToZigOpts) ![:0]u8 {
    return self._toZig(true, opts);
}

fn _toZig(self: String, comptime null_terminate: bool, opts: ToZigOpts) !(if (null_terminate) [:0]u8 else []u8) {
    const isolate = self.local.isolate.handle;
    const allocator = opts.allocator orelse self.local.ctx.call_arena;
    const len: u32 = @intCast(v8.v8__String__Utf8Length(self.handle, isolate));
    const buf = if (null_terminate) try allocator.allocSentinel(u8, len, 0) else try allocator.alloc(u8, len);

    const options = v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8;
    const n = v8.v8__String__WriteUtf8(self.handle, isolate, buf.ptr, buf.len, options);
    std.debug.assert(n == len);
    return buf;
}

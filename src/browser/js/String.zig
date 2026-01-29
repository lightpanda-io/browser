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
const SSO = @import("../../string.zig").String;

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const v8 = js.v8;

const String = @This();

local: *const js.Local,
handle: *const v8.String,

pub fn toSlice(self: String) ![]u8 {
    return self._toSlice(false, self.local.call_arena);
}
pub fn toSliceZ(self: String) ![:0]u8 {
    return self._toSlice(true, self.local.call_arena);
}
pub fn toSliceWithAlloc(self: String, allocator: Allocator) ![]u8 {
    return self._toSlice(false, allocator);
}
fn _toSlice(self: String, comptime null_terminate: bool, allocator: Allocator) !(if (null_terminate) [:0]u8 else []u8) {
    const local = self.local;
    const handle = self.handle;
    const isolate = local.isolate.handle;

    const len = v8.v8__String__Utf8Length(handle, isolate);
    const buf = try (if (comptime null_terminate) allocator.allocSentinel(u8, @intCast(len), 0) else allocator.alloc(u8, @intCast(len)));
    const n = v8.v8__String__WriteUtf8(handle, isolate, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    if (comptime IS_DEBUG) {
        std.debug.assert(n == len);
    }

    return buf;
}

pub fn toSSO(self: String, comptime global: bool) !(if (global) SSO.Global else SSO) {
    if (comptime global) {
        return .{ .str = try self.toSSOWithAlloc(self.local.ctx.arena) };
    }
    return self.toSSOWithAlloc(self.local.call_arena);
}
pub fn toSSOWithAlloc(self: String, allocator: Allocator) !SSO {
    const handle = self.handle;
    const isolate = self.local.isolate.handle;

    const len: usize = @intCast(v8.v8__String__Utf8Length(handle, isolate));

    if (len <= 12) {
        var content: [12]u8 = undefined;
        const n = v8.v8__String__WriteUtf8(handle, isolate, &content[0], content.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
        if (comptime IS_DEBUG) {
            std.debug.assert(n == len);
        }
        // Weird that we do this _after_, but we have to..I've seen weird issues
        // in ReleaseMode where v8 won't write to content if it starts off zero
        // initiated
        @memset(content[len..], 0);
        return .{ .len = @intCast(len), .payload = .{ .content = content } };
    }

    const buf = try allocator.alloc(u8, len);
    const n = v8.v8__String__WriteUtf8(handle, isolate, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    if (comptime IS_DEBUG) {
        std.debug.assert(n == len);
    }

    var prefix: [4]u8 = @splat(0);
    @memcpy(&prefix, buf[0..4]);

    return .{
        .len = @intCast(len),
        .payload = .{ .heap = .{
            .prefix = prefix,
            .ptr = buf.ptr,
        } },
    };
}

pub fn format(self: String, writer: *std.Io.Writer) !void {
    const local = self.local;
    const handle = self.handle;
    const isolate = local.isolate.handle;

    var small: [1024]u8 = undefined;
    const len = v8.v8__String__Utf8Length(handle, isolate);
    var buf = if (len < 1024) &small else local.call_arena.alloc(u8, @intCast(len)) catch return error.WriteFailed;

    const n = v8.v8__String__WriteUtf8(handle, isolate, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    return writer.writeAll(buf[0..n]);
}

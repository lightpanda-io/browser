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
const lp = @import("lightpanda");

const js = @import("js.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const v8 = js.v8;

const String = @This();

local: *const js.Local,
handle: *const v8.String,

// A byte slice that should be handed to JS as a "binary string" — each byte
// 0..255 becomes a JS code unit 0..255 (Latin-1), with no UTF-8 decoding.
// Return this from a Web API method whenever the contract is "one byte per
// JS character" (atob, FileReader.readAsBinaryString, etc.). The framework
// turns it into a V8 string via `String::NewFromOneByte`.
pub const OneByte = struct {
    bytes: []const u8,
};

pub fn toValue(self: String) js.Value {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

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

    const l = v8.v8__String__Utf8Length(handle, isolate);
    const buf = try (if (comptime null_terminate) allocator.allocSentinel(u8, @intCast(l), 0) else allocator.alloc(u8, @intCast(l)));
    const n = v8.v8__String__WriteUtf8(handle, isolate, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    if (comptime IS_DEBUG) {
        std.debug.assert(n == l);
    }

    return buf;
}

pub fn toSSO(self: String, comptime global: bool) !(if (global) lp.String.Global else lp.String) {
    if (comptime global) {
        return .{ .str = try self.toSSOWithAlloc(self.local.ctx.page.frame_arena) };
    }
    return self.toSSOWithAlloc(self.local.call_arena);
}
pub fn toSSOWithAlloc(self: String, allocator: Allocator) !lp.String {
    const handle = self.handle;
    const isolate = self.local.isolate.handle;

    const l: usize = @intCast(v8.v8__String__Utf8Length(handle, isolate));

    if (l <= 12) {
        var content: [12]u8 = undefined;
        const n = v8.v8__String__WriteUtf8(handle, isolate, &content[0], content.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
        if (comptime IS_DEBUG) {
            std.debug.assert(n == l);
        }
        // Weird that we do this _after_, but we have to..I've seen weird issues
        // in ReleaseMode where v8 won't write to content if it starts off zero
        // initiated
        @memset(content[l..], 0);
        return .{ .len = @intCast(l), .payload = .{ .content = content } };
    }

    const buf = try allocator.alloc(u8, l);
    const n = v8.v8__String__WriteUtf8(handle, isolate, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    if (comptime IS_DEBUG) {
        std.debug.assert(n == l);
    }

    var prefix: [4]u8 = @splat(0);
    @memcpy(&prefix, buf[0..4]);

    return .{
        .len = @intCast(l),
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
    const l = v8.v8__String__Utf8Length(handle, isolate);
    var buf = if (l < 1024) &small else local.call_arena.alloc(u8, @intCast(l)) catch return error.WriteFailed;

    const n = v8.v8__String__WriteUtf8(handle, isolate, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    return writer.writeAll(buf[0..n]);
}

pub fn len(self: String) usize {
    return @intCast(v8.v8__String__Utf8Length(self.handle, self.local.isolate.handle));
}

// JS-level character (code unit) count, independent of encoding. Equivalent
// to `s.length` in JavaScript. Use this — not `len()` — when allocating a
// buffer for one-byte / Latin-1 reads.
pub fn lenChars(self: String) usize {
    return @intCast(v8.v8__String__Length(self.handle));
}

// True iff every code unit in the string fits in a single byte (codepoint
// <= 0xFF, i.e. Latin-1). Used by btoa to reject strings with codepoints
// outside the binary-string range.
pub fn containsOnlyOneByte(self: String) bool {
    return v8.v8__String__ContainsOnlyOneByte(self.handle);
}

// Read the string as Latin-1 bytes — each output byte equals the
// corresponding code unit. Caller must have already established (via
// `containsOnlyOneByte`) that no code unit exceeds 0xFF; otherwise V8
// silently truncates to the low byte.
pub fn toOneByteSlice(self: String, allocator: Allocator) ![]u8 {
    const handle = self.handle;
    const isolate = self.local.isolate.handle;
    const length: u32 = @intCast(v8.v8__String__Length(handle));
    const buf = try allocator.alloc(u8, length);
    if (length > 0) {
        v8.v8__String__WriteOneByte(handle, isolate, 0, length, buf.ptr);
    }
    return buf;
}

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
const lp = @import("lightpanda");

const js = @import("js.zig");

const q = js.q;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const String = @This();

local: *const js.Local,
handle: q.JSValue,

// See v8/String.zig: a byte slice handed to JS as a "binary string".
pub const OneByte = struct {
    bytes: []const u8,
};

fn qctx(self: String) *q.JSContext {
    return self.local.ctx.ctx;
}

pub fn toValue(self: String) js.Value {
    return .{
        .local = self.local,
        .handle = self.handle,
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
    const ctx = self.qctx();

    var n: usize = 0;
    const cstr = q.JS_ToCStringLen2(ctx, &n, self.handle, false) orelse return error.JsException;
    defer q.JS_FreeCString(ctx, cstr);

    if (comptime null_terminate) {
        return allocator.dupeZ(u8, cstr[0..n]);
    }
    return allocator.dupe(u8, cstr[0..n]);
}

pub fn toSSO(self: String, comptime global: bool) !(if (global) lp.String.Global else lp.String) {
    if (comptime global) {
        return .{ .str = try self.toSSOWithAlloc(self.local.ctx.page.frame_arena) };
    }
    return self.toSSOWithAlloc(self.local.call_arena);
}

pub fn toSSOWithAlloc(self: String, allocator: Allocator) !lp.String {
    const ctx = self.qctx();
    var n: usize = 0;
    const cstr = q.JS_ToCStringLen2(ctx, &n, self.handle, false) orelse return error.JsException;
    defer q.JS_FreeCString(ctx, cstr);
    return sliceToSSO(cstr[0..n], allocator);
}

// Builds an lp.String (SSO) from a utf-8 slice. The slice is copied.
pub fn sliceToSSO(slice: []const u8, allocator: Allocator) !lp.String {
    const l = slice.len;
    if (l <= 12) {
        var content: [12]u8 = @splat(0);
        @memcpy(content[0..l], slice);
        return .{ .len = @intCast(l), .payload = .{ .content = content } };
    }

    const buf = try allocator.dupe(u8, slice);
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
    const ctx = self.qctx();
    var l: usize = 0;
    const cstr = q.JS_ToCStringLen2(ctx, &l, self.handle, false) orelse return error.WriteFailed;
    defer q.JS_FreeCString(ctx, cstr);
    return writer.writeAll(cstr[0..l]);
}

// @QJS Add a length-only accessor, e.g.
//    JS_EXTERN bool JS_GetStringByteLength(JSContext *ctx, JSValueConst v, size_t *plen);
// Today we materialize (alloc) the whole UTF-8 string just to read its byte
// count, then immediately free it.
// utf-8 byte length
pub fn len(self: String) usize {
    const ctx = self.qctx();
    var l: usize = 0;
    const cstr = q.JS_ToCStringLen2(ctx, &l, self.handle, false) orelse return 0;
    q.JS_FreeCString(ctx, cstr);
    return l;
}

// JS-level character (code unit) count, i.e. `s.length`.
pub fn lenChars(self: String) usize {
    const ctx = self.qctx();
    var out: i64 = 0;
    if (q.JS_GetLength(ctx, self.handle, &out) != 0) {
        return 0;
    }
    return @intCast(out);
}

// True iff every code unit fits in a single byte (Latin-1).
pub fn containsOnlyOneByte(self: String) bool {
    const ctx = self.qctx();
    var l: usize = 0;
    const cstr = q.JS_ToCStringLen2(ctx, &l, self.handle, false) orelse return false;
    defer q.JS_FreeCString(ctx, cstr);

    var i: usize = 0;
    const bytes = cstr[0..l];
    while (i < l) {
        const b = bytes[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        // codepoints above 0xFF need more than 2 utf-8 bytes, or a 2-byte
        // sequence with a lead byte above 0xC3
        if (b > 0xc3 or i + 1 >= l) {
            return false;
        }
        i += 2;
    }
    return true;
}

// @QJS Add a
//    /* returns true and fills buf (len bytes) iff the string is narrow (8-bit) */
//    JS_EXTERN bool JS_GetLatin1Content(JSContext *ctx, JSValueConst v, uint8_t *buf, size_t len);

// Read the string as Latin-1 bytes. Caller must have verified
// containsOnlyOneByte.
pub fn toOneByteSlice(self: String, allocator: Allocator) ![]u8 {
    const ctx = self.qctx();
    var l: usize = 0;
    const cstr = q.JS_ToCStringLen2(ctx, &l, self.handle, false) orelse return error.JsException;
    defer q.JS_FreeCString(ctx, cstr);

    const bytes = cstr[0..l];
    var buf = try allocator.alloc(u8, l);
    var i: usize = 0;
    var pos: usize = 0;
    while (i < l) {
        const b = bytes[i];
        if (b < 0x80) {
            buf[pos] = b;
            i += 1;
        } else {
            std.debug.assert(i + 1 < l);
            buf[pos] = (@as(u8, b & 0x03) << 6) | (bytes[i + 1] & 0x3f);
            i += 2;
        }
        pos += 1;
    }
    return buf[0..pos];
}

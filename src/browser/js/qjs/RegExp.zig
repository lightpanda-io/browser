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

// Built by invoking the global RegExp constructor (quickjs has no direct
// C API for regexps).
const std = @import("std");

const js = @import("js.zig");

const q = js.q;

const RegExp = @This();

local: *const js.Local,
handle: q.JSValue,

// Same flag set as the v8 backend (a v8::RegExp::Flags bitmask).
pub const Flag = struct {
    pub const none: c_int = 0;
    pub const global: c_int = 1 << 0;
    pub const ignore_case: c_int = 1 << 1;
    pub const multiline: c_int = 1 << 2;
    pub const sticky: c_int = 1 << 3;
    pub const unicode: c_int = 1 << 4;
    pub const dot_all: c_int = 1 << 5;
    pub const linear: c_int = 1 << 6;
    pub const has_indices: c_int = 1 << 7;
    pub const unicode_sets: c_int = 1 << 8;
};

pub fn init(local: *const js.Local, pattern: []const u8, flags: c_int) !RegExp {
    var flag_buf: [8]u8 = undefined;
    var flag_len: usize = 0;
    if (flags & Flag.global != 0) {
        flag_buf[flag_len] = 'g';
        flag_len += 1;
    }
    if (flags & Flag.ignore_case != 0) {
        flag_buf[flag_len] = 'i';
        flag_len += 1;
    }
    if (flags & Flag.multiline != 0) {
        flag_buf[flag_len] = 'm';
        flag_len += 1;
    }
    if (flags & Flag.sticky != 0) {
        flag_buf[flag_len] = 'y';
        flag_len += 1;
    }
    if (flags & Flag.unicode != 0) {
        flag_buf[flag_len] = 'u';
        flag_len += 1;
    }
    if (flags & Flag.dot_all != 0) {
        flag_buf[flag_len] = 's';
        flag_len += 1;
    }
    if (flags & Flag.has_indices != 0) {
        flag_buf[flag_len] = 'd';
        flag_len += 1;
    }
    if (flags & Flag.unicode_sets != 0) {
        flag_buf[flag_len] = 'v';
        flag_len += 1;
    }

    const qctx = local.ctx.ctx;
    const global_obj = q.JS_GetGlobalObject(qctx);
    defer q.JS_FreeValue(qctx, global_obj);
    const ctor = q.JS_GetPropertyStr(qctx, global_obj, "RegExp");
    defer q.JS_FreeValue(qctx, ctor);

    var args = [_]q.JSValue{
        local.newString(pattern).handle,
        local.newString(flag_buf[0..flag_len]).handle,
    };
    const handle = q.JS_CallConstructor(qctx, ctor, args.len, &args);
    if (q.JS_IsException(handle)) {
        return error.JsException;
    }
    local.track(handle);
    return .{ .local = local, .handle = handle };
}

// Runs the pattern against `subject`. Returns the result Array (as a
// generic Object) on match, or null on no match.
pub fn exec(self: RegExp, subject: []const u8) !?js.Object {
    const obj = js.Object{ .local = self.local, .handle = self.handle };
    const result = try obj.callMethod(js.Value, "exec", .{subject});
    if (result.isNullOrUndefined()) {
        return null;
    }
    return result.toObject();
}

// Equivalent to `RegExp.prototype.test()` - true iff the pattern matches.
pub fn match(self: RegExp, subject: []const u8) !bool {
    return (try self.exec(subject)) != null;
}

pub fn toValue(self: RegExp) js.Value {
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

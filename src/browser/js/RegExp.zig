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

const v8 = js.v8;

const RegExp = @This();

local: *const js.Local,
handle: *const v8.RegExp,

// Mirrors v8::RegExp::Flags. Combine with bitwise OR.
pub const Flag = struct {
    pub const none: c_int = v8.kRegExpNone;
    pub const global: c_int = v8.kRegExpGlobal;
    pub const ignore_case: c_int = v8.kRegExpIgnoreCase;
    pub const multiline: c_int = v8.kRegExpMultiline;
    pub const sticky: c_int = v8.kRegExpSticky;
    pub const unicode: c_int = v8.kRegExpUnicode;
    pub const dot_all: c_int = v8.kRegExpDotAll;
    pub const linear: c_int = v8.kRegExpLinear;
    pub const has_inSelfdices: c_int = v8.kRegExpHasIndices;
    pub const unicode_sets: c_int = v8.kRegExpUnicodeSets;
};

pub fn init(local: *const js.Local, pattern: []const u8, flags: c_int) !RegExp {
    const pattern_handle = local.isolate.initStringHandle(pattern);
    const handle = v8.v8__RegExp__New(local.handle, pattern_handle, flags) orelse return error.JsException;
    return .{ .local = local, .handle = handle };
}

// Runs the pattern against `subject`. Returns the result Array (as a generic
// Object) on match, or null on no match. Returns error.JsException if V8
// throws — typically when the pattern is malformed for the current flags.
pub fn exec(self: RegExp, subject: []const u8) !?js.Object {
    const local = self.local;
    const subject_handle = local.isolate.initStringHandle(subject);
    const handle = v8.v8__RegExp__Exec(self.handle, local.handle, subject_handle) orelse return error.JsException;
    if (v8.v8__Value__IsNullOrUndefined(@ptrCast(handle))) return null;
    return .{ .local = local, .handle = handle };
}

// Equivalent to `RegExp.prototype.test()` — true iff the pattern matches.
pub fn match(self: RegExp, subject: []const u8) !bool {
    return (try self.exec(subject)) != null;
}

pub fn toValue(self: RegExp) js.Value {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

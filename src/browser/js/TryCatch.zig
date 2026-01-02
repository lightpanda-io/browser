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

const Allocator = std.mem.Allocator;

const TryCatch = @This();

ctx: *js.Context,
handle: v8.c.TryCatch,

pub fn init(self: *TryCatch, ctx: *js.Context) void {
    self.ctx = ctx;
    v8.c.v8__TryCatch__CONSTRUCT(&self.handle, ctx.isolate.handle);
}

pub fn hasCaught(self: TryCatch) bool {
    return v8.c.v8__TryCatch__HasCaught(&self.handle);
}

// the caller needs to deinit the string returned
pub fn exception(self: TryCatch, allocator: Allocator) !?[]const u8 {
    const msg_value = v8.c.v8__TryCatch__Exception(&self.handle) orelse return null;
    const msg = js.Value{ .ctx = self.ctx, .handle = msg_value };
    return try self.ctx.valueToString(msg, .{ .allocator = allocator });
}

// the caller needs to deinit the string returned
pub fn stack(self: TryCatch, allocator: Allocator) !?[]const u8 {
    const ctx = self.ctx;
    const s_value = v8.c.v8__TryCatch__StackTrace(&self.handle, ctx.handle) orelse return null;
    const s = js.Value{ .ctx = ctx, .handle = s_value };
    return try ctx.valueToString(s, .{ .allocator = allocator });
}

// the caller needs to deinit the string returned
pub fn sourceLine(self: TryCatch, allocator: Allocator) !?[]const u8 {
    const ctx = self.ctx;
    const msg = v8.c.v8__TryCatch__Message(&self.handle) orelse return null;
    const source_line_handle = v8.c.v8__Message__GetSourceLine(msg, ctx.handle) orelse return null;
    return try ctx.jsStringToZig(source_line_handle, .{ .allocator = allocator });
}

pub fn sourceLineNumber(self: TryCatch) ?u32 {
    const ctx = self.ctx;
    const msg = v8.c.v8__TryCatch__Message(&self.handle) orelse return null;
    const line = v8.c.v8__Message__GetLineNumber(msg, ctx.handle);
    if (line < 0) {
        return null;
    }
    return @intCast(line);
}

// a shorthand method to return either the entire stack message
// or just the exception message
// - in Debug mode return the stack if available
// - otherwise return the exception if available
// the caller needs to deinit the string returned
pub fn err(self: TryCatch, allocator: Allocator) !?[]const u8 {
    if (comptime @import("builtin").mode == .Debug) {
        if (try self.stack(allocator)) |msg| {
            return msg;
        }
    }
    return try self.exception(allocator);
}

pub fn deinit(self: *TryCatch) void {
    v8.c.v8__TryCatch__DESTRUCT(&self.handle);
}

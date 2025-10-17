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

inner: v8.TryCatch,
context: *const js.Context,

pub fn init(self: *TryCatch, context: *const js.Context) void {
    self.context = context;
    self.inner.init(context.isolate);
}

pub fn hasCaught(self: TryCatch) bool {
    return self.inner.hasCaught();
}

// the caller needs to deinit the string returned
pub fn exception(self: TryCatch, allocator: Allocator) !?[]const u8 {
    const msg = self.inner.getException() orelse return null;
    return try self.context.valueToString(msg, .{ .allocator = allocator });
}

// the caller needs to deinit the string returned
pub fn stack(self: TryCatch, allocator: Allocator) !?[]const u8 {
    const context = self.context;
    const s = self.inner.getStackTrace(context.v8_context) orelse return null;
    return try context.valueToString(s, .{ .allocator = allocator });
}

// the caller needs to deinit the string returned
pub fn sourceLine(self: TryCatch, allocator: Allocator) !?[]const u8 {
    const context = self.context;
    const msg = self.inner.getMessage() orelse return null;
    const sl = msg.getSourceLine(context.v8_context) orelse return null;
    return try context.jsStringToZig(sl, .{ .allocator = allocator });
}

pub fn sourceLineNumber(self: TryCatch) ?u32 {
    const context = self.context;
    const msg = self.inner.getMessage() orelse return null;
    return msg.getLineNumber(context.v8_context);
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
    self.inner.deinit();
}

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

const Allocator = std.mem.Allocator;

const TryCatch = @This();

handle: v8.TryCatch,
local: *const js.Local,

pub fn init(self: *TryCatch, l: *const js.Local) void {
    self.local = l;
    v8.v8__TryCatch__CONSTRUCT(&self.handle, l.isolate.handle);
}

pub fn hasCaught(self: TryCatch) bool {
    return v8.v8__TryCatch__HasCaught(&self.handle);
}

pub fn caught(self: TryCatch, allocator: Allocator) ?Caught {
    if (!self.hasCaught()) {
        return null;
    }

    const l = self.local;
    const line: ?u32 = blk: {
        const handle = v8.v8__TryCatch__Message(&self.handle) orelse return null;
        const line = v8.v8__Message__GetLineNumber(handle, l.handle);
        break :blk if (line < 0) null else @intCast(line);
    };

    const exception: ?[]const u8 = blk: {
        const handle = v8.v8__TryCatch__Exception(&self.handle) orelse break :blk null;
        break :blk l.valueHandleToString(@ptrCast(handle), .{ .allocator = allocator }) catch |err| @errorName(err);
    };

    const stack: ?[]const u8 = blk: {
        const handle = v8.v8__TryCatch__StackTrace(&self.handle, l.handle) orelse break :blk null;
        break :blk l.valueHandleToString(@ptrCast(handle), .{ .allocator = allocator }) catch |err| @errorName(err);
    };

    return .{
        .line = line,
        .stack = stack,
        .caught = true,
        .exception = exception,
    };
}

pub fn caughtOrError(self: TryCatch, allocator: Allocator, err: anyerror) Caught {
    return self.caught(allocator) orelse .{
        .caught = false,
        .line = null,
        .stack = null,
        .exception = @errorName(err),
    };
}

pub fn deinit(self: *TryCatch) void {
    v8.v8__TryCatch__DESTRUCT(&self.handle);
}

pub const Caught = struct {
    line: ?u32,
    caught: bool,
    stack: ?[]const u8,
    exception: ?[]const u8,

    pub fn format(self: Caught, writer: *std.Io.Writer) !void {
        const separator = @import("../../log.zig").separator();
        try writer.print("{s}exception: {?s}", .{ separator, self.exception });
        try writer.print("{s}stack: {?s}", .{ separator, self.stack });
        try writer.print("{s}line: {?d}", .{ separator, self.line });
        try writer.print("{s}caught: {any}", .{ separator, self.caught });
    }

    pub fn logFmt(self: Caught, comptime prefix: []const u8, writer: anytype) !void {
        try writer.write(prefix ++ ".exception", self.exception orelse "???");
        try writer.write(prefix ++ ".stack", self.stack orelse "na");
        try writer.write(prefix ++ ".line", self.line);
        try writer.write(prefix ++ ".caught", self.caught);
    }
};

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

// v8 TryCatch emulation. quickjs keeps a single pending exception on the
// context; this wrapper captures it lazily (and owns it once captured) so
// the same caught/rethrow/deinit flow works.
const std = @import("std");
const lp = @import("lightpanda");

const js = @import("js.zig");

const q = js.q;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const TryCatch = @This();

local: *const js.Local,
exception: ?q.JSValue = null,

pub fn init(self: *TryCatch, l: *const js.Local) void {
    self.* = .{ .local = l };
}

fn capture(self: *TryCatch) ?q.JSValue {
    if (self.exception) |e| {
        return e;
    }
    const ctx = self.local.ctx.ctx;
    if (!q.JS_HasException(ctx)) {
        return null;
    }
    self.exception = q.JS_GetException(ctx);
    return self.exception;
}

pub fn hasCaught(self: *TryCatch) bool {
    return self.capture() != null;
}

pub fn rethrow(self: *TryCatch) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.hasCaught());
    }
    const ctx = self.local.ctx.ctx;
    if (self.capture()) |e| {
        _ = q.JS_Throw(ctx, q.JS_DupValue(ctx, e));
    }
}

pub fn caught(self: *TryCatch, allocator: Allocator) ?Caught {
    const e = self.capture() orelse return null;
    const l = self.local;
    const value = js.Value{ .local = l, .handle = e };

    const exception: ?[]const u8 = blk: {
        if (value.isObject()) {
            const js_obj = value.toObject();
            if (js_obj.has("message")) {
                const msg = js_obj.get("message") catch break :blk null;
                if (msg.isString()) |js_str| {
                    break :blk js_str.toSliceWithAlloc(allocator) catch |err| @errorName(err);
                }
            }
        }
        if (value.isString()) |js_str| {
            break :blk js_str.toSliceWithAlloc(allocator) catch |err| @errorName(err);
        }
        break :blk value.toStringSliceWithAlloc(allocator) catch null;
    };

    const stack: ?[]const u8 = blk: {
        if (!value.isObject()) {
            break :blk null;
        }
        const js_obj = value.toObject();
        if (!js_obj.has("stack")) {
            break :blk null;
        }
        const s = js_obj.get("stack") catch break :blk null;
        if (s.isString()) |js_str| {
            break :blk js_str.toSliceWithAlloc(allocator) catch |err| @errorName(err);
        }
        break :blk null;
    };

    return .{
        .line = null,
        .stack = stack,
        .caught = true,
        .exception = exception,
    };
}

pub fn caughtOrError(self: *TryCatch, allocator: Allocator, err: anyerror) Caught {
    return self.caught(allocator) orelse .{
        .caught = false,
        .line = null,
        .stack = null,
        .exception = @errorName(err),
    };
}

pub fn deinit(self: *TryCatch) void {
    if (self.exception) |e| {
        q.JS_FreeValue(self.local.ctx.ctx, e);
        self.exception = null;
    }
}

pub const Caught = struct {
    line: ?u32 = null,
    caught: bool = false,
    stack: ?[]const u8 = null,
    exception: ?[]const u8 = null,

    pub fn format(self: Caught, writer: *std.Io.Writer) !void {
        const separator = lp.log.separator();
        try writer.print("{s}exception: {?s}", .{ separator, self.exception });
        try writer.print("{s}stack: {?s}", .{ separator, self.stack });
        try writer.print("{s}line: {?d}", .{ separator, self.line });
        try writer.print("{s}caught: {any}", .{ separator, self.caught });
    }

    pub fn logFmt(self: Caught, prefix: []const u8, writer: anytype) !void {
        var buf: [64]u8 = undefined;
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.exception", .{prefix}), self.exception orelse "???");
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.stack", .{prefix}), self.stack orelse "na");
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.line", .{prefix}), self.line);
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.caught", .{prefix}), self.caught);
    }

    pub fn jsonStringify(self: Caught, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("exception");
        try jw.write(self.exception);
        try jw.objectField("stack");
        try jw.write(self.stack);
        try jw.objectField("line");
        try jw.write(self.line);
        try jw.objectField("caught");
        try jw.write(self.caught);
        try jw.endObject();
    }
};

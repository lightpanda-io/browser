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

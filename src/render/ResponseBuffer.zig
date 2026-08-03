// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Dynamically growing response writer with a hard capacity.

const std = @import("std");

const ResponseBuffer = @This();

out: std.Io.Writer.Allocating,
writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },
limit: usize,
failed: bool = false,

const vtable: std.Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
};

pub fn init(allocator: std.mem.Allocator, limit: usize) ResponseBuffer {
    return .{ .out = .init(allocator), .limit = limit };
}

pub fn deinit(self: *ResponseBuffer) void {
    self.out.deinit();
}

pub fn buffered(self: *const ResponseBuffer) []const u8 {
    return self.out.writer.buffered();
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *ResponseBuffer = @alignCast(@fieldParentPtr("writer", writer));
    if (self.failed) return error.WriteFailed;

    var additional: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        additional = std.math.add(usize, additional, bytes.len) catch return self.fail();
    }
    const splat_bytes = std.math.mul(usize, data[data.len - 1].len, splat) catch return self.fail();
    additional = std.math.add(usize, additional, splat_bytes) catch return self.fail();

    const current = self.out.writer.end;
    if (additional > self.limit or current > self.limit - additional) return self.fail();
    const needed = current + additional;
    if (self.out.writer.buffer.len < needed) {
        const capacity = @min(std.ArrayList(u8).growCapacity(needed), self.limit);
        self.out.ensureTotalCapacityPrecise(capacity) catch return self.fail();
    }
    return self.out.writer.writeSplat(data, splat) catch return self.fail();
}

fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}

fn fail(self: *ResponseBuffer) error{WriteFailed} {
    self.failed = true;
    return error.WriteFailed;
}

test "ResponseBuffer: limit failure is transactional" {
    var out: ResponseBuffer = .init(std.testing.allocator, 16);
    defer out.deinit();

    try out.writer.writeAll("1234567890");
    try std.testing.expectError(error.WriteFailed, out.writer.writeAll("1234567"));
    try std.testing.expect(out.failed);
    try std.testing.expectEqualStrings("1234567890", out.buffered());
}

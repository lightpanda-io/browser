const std = @import("std");

/// Overwriting ring buffer implementation.
/// Useful if you're not interested with stale data.
pub fn Overwriting(
    comptime T: type,
    comptime backing: union(enum) { array: usize, slice },
) type {
    switch (comptime backing) {
        .array => |size| if (size == 0) @panic("invalid ring buffer size"),
        else => {},
    }

    return struct {
        const Self = @This();

        /// Storage.
        buffer: switch (backing) {
            .array => |size| [size]T,
            .slice => []T,
        },
        /// Next write index.
        write_idx: usize = 0,
        /// Length of items ring currently have.
        count: usize = 0,

        fn initArray() Self {
            return .{ .buffer = undefined };
        }

        fn initSlice(allocator: std.mem.Allocator, size: usize) !Self {
            if (size == 0) return error.InvalidSize;
            return .{ .buffer = try allocator.alloc(T, size) };
        }

        pub const init = switch (backing) {
            .array => initArray,
            .slice => initSlice,
        };

        /// Puts an item.
        pub fn put(self: *Self, item: T) void {
            self.buffer[self.write_idx] = item;
            // Wrapping addition.
            self.write_idx = (self.write_idx + 1) % self.buffer.len;
            self.count = @min(self.count + 1, self.buffer.len);
        }

        /// Returns the oldest item.
        pub fn get(self: *Self) ?T {
            // No items.
            if (self.count == 0) {
                return null;
            }

            const read_idx = (self.write_idx + self.buffer.len - self.count) % self.buffer.len;
            const item = self.buffer[read_idx];
            self.count -= 1;
            return item;
        }

        /// Returns slices to items in ring buffer.
        /// In order to avoid memcpy at this level, this function returns
        /// 2 slices. Second slice will be empty if items can be represented
        /// in a contigious way.
        pub fn slice(self: *const Self) struct { first: []const T, second: []const T } {
            if (self.count == 0) {
                return .{ .first = &.{}, .second = &.{} };
            }

            const read_idx = (self.write_idx + self.buffer.len - self.count) % self.buffer.len;

            if (read_idx < self.write_idx) {
                return .{ .first = self.buffer[read_idx..self.write_idx], .second = &.{} };
            }

            return .{ .first = self.buffer[read_idx..], .second = self.buffer[0..self.write_idx] };
        }
    };
}

const std = @import("std");

pub const BrowserCommand = union(enum) {
    navigate: []u8,
    back,
    forward,
    reload,
    stop,

    pub fn deinit(self: BrowserCommand, allocator: std.mem.Allocator) void {
        switch (self) {
            .navigate => |url| allocator.free(url),
            else => {},
        }
    }
};

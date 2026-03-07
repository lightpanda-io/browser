const std = @import("std");

pub const BrowserCommand = union(enum) {
    navigate: []u8,
    history_traverse: usize,
    back,
    forward,
    reload,
    stop,
    zoom_in,
    zoom_out,
    zoom_reset,

    pub fn deinit(self: BrowserCommand, allocator: std.mem.Allocator) void {
        switch (self) {
            .navigate => |url| allocator.free(url),
            else => {},
        }
    }
};

const std = @import("std");

pub const BrowserCommand = union(enum) {
    navigate: []u8,
    history_traverse: usize,
    tab_activate: usize,
    tab_close: usize,
    back,
    forward,
    reload,
    stop,
    tab_new,
    tab_next,
    tab_previous,
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

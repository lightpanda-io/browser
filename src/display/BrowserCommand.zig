const std = @import("std");

pub const BrowserCommand = union(enum) {
    pub const Download = struct {
        url: []u8,
        suggested_filename: []u8,
    };

    navigate: []u8,
    download: Download,
    history_traverse: usize,
    download_remove: usize,
    tab_activate: usize,
    tab_close: usize,
    back,
    forward,
    reload,
    stop,
    tab_new,
    tab_next,
    tab_previous,
    tab_reopen_closed,
    zoom_in,
    zoom_out,
    zoom_reset,

    pub fn deinit(self: BrowserCommand, allocator: std.mem.Allocator) void {
        switch (self) {
            .navigate => |url| allocator.free(url),
            .download => |download| {
                allocator.free(download.url);
                allocator.free(download.suggested_filename);
            },
            else => {},
        }
    }
};

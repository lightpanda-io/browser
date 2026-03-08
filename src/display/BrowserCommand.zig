const std = @import("std");

pub const BrowserCommand = union(enum) {
    pub const Download = struct {
        url: []u8,
        suggested_filename: []u8,
    };

    pub const ActivateLinkRegion = struct {
        x: f64,
        y: f64,
        url: []u8,
        dom_path: []u16,
        suggested_filename: []u8,
        target_name: []u8,
        open_in_new_tab: bool,
    };

    pub const NavigateTarget = struct {
        url: []u8,
        target_name: []u8,
    };

    activate_link_region: ActivateLinkRegion,
    navigate: []u8,
    navigate_new_tab: []u8,
    navigate_target_tab: NavigateTarget,
    download: Download,
    history_traverse: usize,
    history_clear_session,
    bookmark_add_current,
    bookmark_open: usize,
    bookmark_remove: usize,
    download_source: usize,
    download_remove: usize,
    download_clear,
    tab_activate: usize,
    tab_close: usize,
    tab_duplicate_index: usize,
    tab_reload_index: usize,
    back,
    forward,
    reload,
    stop,
    tab_new,
    tab_duplicate,
    tab_next,
    tab_previous,
    tab_reopen_closed,
    home,
    page_tabs,
    page_history,
    page_bookmarks,
    page_downloads,
    page_settings,
    settings_toggle_restore_session,
    settings_toggle_script_popups,
    settings_default_zoom_in,
    settings_default_zoom_out,
    settings_default_zoom_reset,
    settings_set_homepage_to_current,
    settings_clear_homepage,
    zoom_in,
    zoom_out,
    zoom_reset,

    pub fn deinit(self: BrowserCommand, allocator: std.mem.Allocator) void {
        switch (self) {
            .activate_link_region => |activation| {
                allocator.free(activation.url);
                allocator.free(activation.dom_path);
                allocator.free(activation.suggested_filename);
                allocator.free(activation.target_name);
            },
            .navigate => |url| allocator.free(url),
            .navigate_new_tab => |url| allocator.free(url),
            .navigate_target_tab => |target| {
                allocator.free(target.url);
                allocator.free(target.target_name);
            },
            .download => |download| {
                allocator.free(download.url);
                allocator.free(download.suggested_filename);
            },
            else => {},
        }
    }
};

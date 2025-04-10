const URL = @import("url.zig").URL;

pub const Notification = union(enum) {
    page_navigate: PageEvent,
    page_navigated: PageEvent,

    pub const PageEvent = struct {
        ts: u32,
        url: *const URL,
    };
};

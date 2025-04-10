const URL = @import("url.zig").URL;

pub const Notification = union(enum) {
    page_navigate: PageEvent,
    page_navigated: PageEvent,

    pub const PageEvent = struct {
        timestamp: u32,
        url: *const URL,
    };
};

const URL = @import("url.zig").URL;
const browser = @import("browser/browser.zig");

pub const Notification = union(enum) {
    page_navigate: PageNavigate,
    page_navigated: PageNavigated,
    context_created: ContextCreated,

    pub const PageNavigate = struct {
        timestamp: u32,
        url: *const URL,
        reason: browser.NavigateReason,
    };

    pub const PageNavigated = struct {
        timestamp: u32,
        url: *const URL,
    };

    pub const ContextCreated = struct {
        origin: []const u8,
    };
};

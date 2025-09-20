const std = @import("std");
const App = @import("app.zig").App;
const Browser = @import("browser/browser.zig").Browser;
const Session = @import("browser/session.zig").Session;
const Page = @import("browser/page.zig").Page;
const Scheduler = @import("browser/Scheduler.zig");
const CDPT = @import("cdp/cdp.zig").CDPT;
const BrowserContext = @import("cdp/cdp.zig").BrowserContext;

export fn lightpanda_app_init() ?*anyopaque {
    const allocator = std.heap.c_allocator;

    @import("log.zig").opts.level = .warn;

    const app = App.init(allocator, .{
        // .run_mode = .serve,
        // .tls_verify_host = false
        .run_mode = .serve,
        .tls_verify_host = false,
        // .http_proxy = null,
        // .proxy_bearer_token = args.proxyBearerToken(),
        // .tls_verify_host = args.tlsVerifyHost(),
        // .http_timeout_ms = args.httpTimeout(),
        // .http_connect_timeout_ms = args.httpConnectTiemout(),
        // .http_max_host_open = args.httpMaxHostOpen(),
        // .http_max_concurrent = args.httpMaxConcurrent(),
    }) catch return null;

    return app;
}

export fn lightpanda_app_deinit(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.deinit();
}

export fn lightpanda_browser_init(app_ptr: *anyopaque) ?*anyopaque {
    const app: *App = @ptrCast(@alignCast(app_ptr));

    const browser = std.heap.c_allocator.create(Browser) catch return null;
    browser.* = Browser.init(app) catch return null;

    return browser;
}

export fn lightpanda_browser_deinit(browser_ptr: *anyopaque) void {
    const browser: *Browser = @ptrCast(@alignCast(browser_ptr));
    browser.deinit();
}

export fn lightpanda_browser_new_session(browser_ptr: *anyopaque) ?*anyopaque {
    const browser: *Browser = @ptrCast(@alignCast(browser_ptr));
    const session = browser.newSession() catch return null;
    return session;
}

export fn lightpanda_session_create_page(session_ptr: *anyopaque) ?*anyopaque {
    const session: *Session = @ptrCast(@alignCast(session_ptr));
    const page = session.createPage() catch return null;
    page.auto_enable_dom_monitoring = true;
    return page;
}

export fn lightpanda_session_page(session_ptr: *anyopaque) ?*anyopaque {
    const session: *Session = @ptrCast(@alignCast(session_ptr));
    return &session.page;
}

export fn lightpanda_page_navigate(page_ptr: *anyopaque, url: [*:0]const u8) void {
    const page: *Page = @ptrCast(@alignCast(page_ptr));
    page.navigate(std.mem.span(url), .{}) catch return;
}

const NativeClientHandler = *const fn (ctx: *anyopaque, message: [*:0]const u8) callconv(.c) void;

const NativeClient = struct {
    allocator: std.mem.Allocator,
    send_arena: std.heap.ArenaAllocator,
    // sent: std.ArrayListUnmanaged(std.json.Value) = .{},
    // serialized: std.ArrayListUnmanaged([]const u8) = .{},
    handler: NativeClientHandler,
    ctx: *anyopaque,

    fn init(alloc: std.mem.Allocator, handler: NativeClientHandler, ctx: *anyopaque) NativeClient {
        return .{ .allocator = alloc, .send_arena = std.heap.ArenaAllocator.init(alloc), .handler = handler, .ctx = ctx };
    }

    pub fn sendJSON(self: *NativeClient, message: anytype, opts: std.json.Stringify.Options) !void {
        var opts_copy = opts;
        opts_copy.whitespace = .indent_2;
        const serialized = try std.json.Stringify.valueAlloc(self.allocator, message, opts_copy);

        const slice = try self.allocator.dupeZ(u8, serialized);
        defer self.allocator.free(slice);
        self.handler(self.ctx, slice.ptr);
    }

    pub fn sendJSONRaw(self: *NativeClient, buf: std.ArrayListUnmanaged(u8)) !void {
        const msg = buf.items[10..]; // CDP adds 10 0s for a WebSocket header.
        const slice = try self.allocator.dupeZ(u8, msg);
        defer self.allocator.free(slice);
        self.handler(self.ctx, slice.ptr);
    }
};

const CDP = CDPT(struct {
    pub const Client = *NativeClient;
});

export fn lightpanda_cdp_init(app_ptr: *anyopaque, handler: NativeClientHandler, ctx: *anyopaque) ?*anyopaque {
    const app: *App = @ptrCast(@alignCast(app_ptr));

    const client = app.allocator.create(NativeClient) catch return null;
    client.* = NativeClient.init(app.allocator, handler, ctx);

    const cdp = app.allocator.create(CDP) catch return null;
    cdp.* = CDP.init(app, client) catch return null;

    return cdp;
}

export fn lightpanda_cdp_deinit(cdp_ptr: *anyopaque) void {
    const cdp: *CDP = @ptrCast(@alignCast(cdp_ptr));
    cdp.deinit();
}

export fn lightpanda_cdp_create_browser_context(cdp_ptr: *anyopaque) ?[*:0]const u8 {
    const cdp: *CDP = @ptrCast(@alignCast(cdp_ptr));
    const id = cdp.createBrowserContext() catch return null;

    const page = cdp.browser_context.?.session.createPage() catch return null;
    page.auto_enable_dom_monitoring = true;

    const target_id = cdp.target_id_gen.next();
    cdp.browser_context.?.target_id = target_id;

    const session_id = cdp.session_id_gen.next();
    cdp.browser_context.?.extra_headers.clearRetainingCapacity();
    cdp.browser_context.?.session_id = session_id;

    const slice = cdp.allocator.dupeZ(u8, id) catch return null;
    return slice.ptr;
}

export fn lightpanda_cdp_browser(cdp_ptr: *anyopaque) ?*anyopaque {
    const cdp: *CDP = @ptrCast(@alignCast(cdp_ptr));
    return &cdp.browser;
}

export fn lightpanda_cdp_process_message(cdp_ptr: *anyopaque, msg: [*:0]const u8) void {
    const cdp: *CDP = @ptrCast(@alignCast(cdp_ptr));
    cdp.processMessage(std.mem.span(msg)) catch return;
}

export fn lightpanda_cdp_browser_context(cdp_ptr: *anyopaque) *anyopaque {
    const cdp: *CDP = @ptrCast(@alignCast(cdp_ptr));
    return &cdp.browser_context.?;
}

// returns -1 if no session/page, or if no events reamin, otherwise returns
// milliseconds until next scheduled task
export fn lightpanda_cdp_page_wait(cdp_ptr: *anyopaque, ms: i32) c_int {
    const cdp: *CDP = @ptrCast(@alignCast(cdp_ptr));
    _ = cdp.pageWait(ms);

    // it's okay to panic if the session or page don't exist.
    const scheduler = &cdp.browser.session.?.page.?.scheduler;
    return cdp_peek_next_delay_ms(scheduler) orelse -1;
}

fn cdp_peek_next_delay_ms(scheduler: *Scheduler) ?i32 {
    var queue = queue: {
        if (scheduler.high_priority.count() == 0) {
            if (scheduler.low_priority.count() == 0) return null;
            break :queue scheduler.low_priority;
        } else {
            break :queue scheduler.high_priority;
        }
    };

    const now = std.time.milliTimestamp();
    // we know this must exist because the count was not 0.
    const next_task = queue.peek().?;

    const time_to_next = next_task.ms - now;
    return if (time_to_next > 0) @intCast(time_to_next) else 0;
}

export fn lightpanda_browser_context_session(browser_context_ptr: *anyopaque) *anyopaque {
    const browser_context: *BrowserContext(CDP) = @ptrCast(@alignCast(browser_context_ptr));
    return browser_context.session;
}

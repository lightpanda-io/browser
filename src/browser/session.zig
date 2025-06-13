// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Env = @import("env.zig").Env;
const Page = @import("page.zig").Page;
const URL = @import("../url.zig").URL;
const Browser = @import("browser.zig").Browser;
const NavigateOpts = @import("page.zig").NavigateOpts;

const log = @import("../log.zig");
const parser = @import("netsurf.zig");
const storage = @import("storage/storage.zig");

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
pub const Session = struct {
    browser: *Browser,

    // Used to create our Inspector and in the BrowserContext.
    arena: Allocator,

    // The page's arena is unsuitable for data that has to existing while
    // navigating from one page to another. For example, if we're clicking
    // on an HREF, the URL exists in the original page (where the click
    // originated) but also has to exist in the new page.
    // While we could use the Session's arena, this could accumulate a lot of
    // memory if we do many navigation events. The `transfer_arena` is meant to
    // bridge the gap: existing long enough to store any data needed to end one
    // page and start another.
    transfer_arena: Allocator,

    executor: Env.ExecutionWorld,
    storage_shed: storage.Shed,
    cookie_jar: storage.CookieJar,

    page: ?Page = null,

    pub fn init(self: *Session, browser: *Browser) !void {
        var executor = try browser.env.newExecutionWorld();
        errdefer executor.deinit();

        const allocator = browser.app.allocator;
        self.* = .{
            .browser = browser,
            .executor = executor,
            .arena = browser.session_arena.allocator(),
            .storage_shed = storage.Shed.init(allocator),
            .cookie_jar = storage.CookieJar.init(allocator),
            .transfer_arena = browser.transfer_arena.allocator(),
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.page != null) {
            self.removePage();
        }
        self.cookie_jar.deinit();
        self.storage_shed.deinit();
        self.executor.deinit();
    }

    // NOTE: the caller is not the owner of the returned value,
    // the pointer on Page is just returned as a convenience
    pub fn createPage(self: *Session) !*Page {
        std.debug.assert(self.page == null);

        // Start netsurf memory arena.
        // We need to init this early as JS event handlers may be registered through Runtime.evaluate before the first html doc is loaded
        try parser.init();

        const page_arena = &self.browser.page_arena;
        _ = page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });
        _ = self.browser.state_pool.reset(.{ .retain_with_limit = 4 * 1024 });

        self.page = @as(Page, undefined);
        const page = &self.page.?;
        try Page.init(page, page_arena.allocator(), self);

        log.debug(.browser, "create page", .{});
        // start JS env
        // Inform CDP the main page has been created such that additional context for other Worlds can be created as well
        self.browser.notification.dispatch(.page_created, page);

        return page;
    }

    pub fn removePage(self: *Session) void {
        // Inform CDP the page is going to be removed, allowing other worlds to remove themselves before the main one
        self.browser.notification.dispatch(.page_remove, .{});

        std.debug.assert(self.page != null);

        // Cleanup is a bit sensitive. We could still have inflight I/O. For
        // example, we could have an XHR request which is still in the connect
        // phase. It's important that we clean these up, as they're holding onto
        // limited resources (like our fixed-sized http state pool).
        //
        // First thing we do, is endScope() which will execute the destructor
        // of any type that registered a destructor (e.g. XMLHttpRequest).
        // This will shutdown any pending sockets, which begins our cleaning
        // processed
        self.executor.endScope();

        // Second thing we do is reset the loop. This increments the loop ctx_id
        // so that any "stale" timeouts we process will get ignored. We need to
        // do this BEFORE running the loop because, at this point, things like
        // window.setTimeout and running microtasks should be ignored
        self.browser.app.loop.reset();

        self.page = null;

        // clear netsurf memory arena.
        parser.deinit();

        log.debug(.browser, "remove page", .{});
    }

    pub fn currentPage(self: *Session) ?*Page {
        return &(self.page orelse return null);
    }
};

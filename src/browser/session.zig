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

const ArenaAllocator = std.heap.ArenaAllocator;

const Env = @import("env.zig").Env;
const Page = @import("page.zig").Page;
const Browser = @import("browser.zig").Browser;

const parser = @import("netsurf.zig");
const storage = @import("storage/storage.zig");

const log = std.log.scoped(.session);

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
pub const Session = struct {
    browser: *Browser,

    // Used to create our Inspector and in the BrowserContext.
    arena: ArenaAllocator,

    executor: Env.Executor,
    storage_shed: storage.Shed,
    cookie_jar: storage.CookieJar,

    page: ?Page = null,

    pub fn init(self: *Session, browser: *Browser) !void {
        var executor = try browser.env.newExecutor();
        errdefer executor.deinit();

        const allocator = browser.app.allocator;
        self.* = .{
            .browser = browser,
            .executor = executor,
            .arena = ArenaAllocator.init(allocator),
            .storage_shed = storage.Shed.init(allocator),
            .cookie_jar = storage.CookieJar.init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.page != null) {
            self.removePage();
        }
        self.arena.deinit();
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

        self.page = @as(Page, undefined);
        const page = &self.page.?;
        try Page.init(page, page_arena.allocator(), self);

        // start JS env
        log.debug("start new js scope", .{});
        // Inform CDP the main page has been created such that additional context for other Worlds can be created as well
        self.browser.notification.dispatch(.page_created, page);

        return page;
    }

    pub fn removePage(self: *Session) void {
        // Inform CDP the page is going to be removed, allowing other worlds to remove themselves before the main one
        self.browser.notification.dispatch(.page_remove, .{});

        std.debug.assert(self.page != null);
        // Reset all existing callbacks.
        self.browser.app.loop.reset();
        self.executor.endScope();
        self.page = null;

        // clear netsurf memory arena.
        parser.deinit();
    }

    pub fn currentPage(self: *Session) ?*Page {
        return &(self.page orelse return null);
    }

    pub fn pageNavigate(self: *Session, url_string: []const u8) !void {
        // currently, this is only called from the page, so let's hope
        // it isn't null!
        std.debug.assert(self.page != null);

        // can't use the page arena, because we're about to reset it
        // and don't want to use the session's arena, because that'll start to
        // look like a leak if we navigate from page to page a lot.
        var buf: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const url = try self.page.?.url.resolve(fba.allocator(), url_string);

        self.removePage();
        var page = try self.createPage();
        return page.navigate(url, .{
            .reason = .anchor,
        });
    }
};

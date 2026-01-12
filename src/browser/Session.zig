// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const log = @import("../log.zig");

const js = @import("js/js.zig");
const storage = @import("webapi/storage/storage.zig");
const Navigation = @import("webapi/navigation/Navigation.zig");
const History = @import("webapi/History.zig");

const Page = @import("Page.zig");
const Browser = @import("Browser.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

// Session is like a browser's tab.
// It owns the js env and the loader for all the pages of the session.
// You can create successively multiple pages for a session, but you must
// deinit a page before running another one.
const Session = @This();

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

executor: js.ExecutionWorld,
cookie_jar: storage.Cookie.Jar,
storage_shed: storage.Shed,

history: History,
navigation: Navigation,

page: ?*Page = null,

pub fn init(self: *Session, browser: *Browser) !void {
    var executor = try browser.env.newExecutionWorld();
    errdefer executor.deinit();

    const allocator = browser.app.allocator;
    const session_allocator = browser.session_arena.allocator();

    self.* = .{
        .browser = browser,
        .executor = executor,
        .storage_shed = .{},
        .arena = session_allocator,
        .cookie_jar = storage.Cookie.Jar.init(allocator),
        .navigation = .{},
        .history = .{},
        .transfer_arena = browser.transfer_arena.allocator(),
    };
}

pub fn deinit(self: *Session) void {
    if (self.page != null) {
        self.removePage();
    }
    self.cookie_jar.deinit();
    self.storage_shed.deinit(self.browser.app.allocator);
    self.executor.deinit();
}

// NOTE: the caller is not the owner of the returned value,
// the pointer on Page is just returned as a convenience
pub fn createPage(self: *Session) !*Page {
    lp.assert(self.page == null, "Session.createPage - page not null", .{});

    const page_arena = &self.browser.page_arena;
    _ = page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });

    self.page = try Page.init(page_arena.allocator(), self.browser.call_arena.allocator(), self);
    const page = self.page.?;

    // Creates a new NavigationEventTarget for this page.
    try self.navigation.onNewPage(page);

    if (comptime IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }
    // start JS env
    // Inform CDP the main page has been created such that additional context for other Worlds can be created as well
    self.browser.notification.dispatch(.page_created, page);

    return page;
}

pub fn removePage(self: *Session) void {
    // Inform CDP the page is going to be removed, allowing other worlds to remove themselves before the main one
    self.browser.notification.dispatch(.page_remove, .{});
    lp.assert(self.page != null, "Session.removePage - page is null", .{});

    self.page.?.deinit();
    self.page = null;

    self.navigation.onRemovePage();

    if (comptime IS_DEBUG) {
        log.debug(.browser, "remove page", .{});
    }
}

pub fn currentPage(self: *Session) ?*Page {
    return self.page orelse return null;
}

pub const WaitResult = enum {
    done,
    no_page,
    cdp_socket,
    navigate,
};

pub fn wait(self: *Session, wait_ms: u32) WaitResult {
    while (true) {
        const page = self.page orelse return .no_page;
        switch (page.wait(wait_ms)) {
            .navigate => self.processScheduledNavigation() catch return .done,
            else => |result| return result,
        }
        // if we've successfull navigated, we'll give the new page another
        // page.wait(wait_ms)
    }
}

fn processScheduledNavigation(self: *Session) !void {
    const qn = self.page.?._queued_navigation.?;
    defer _ = self.browser.transfer_arena.reset(.{ .retain_with_limit = 8 * 1024 });

    // This was already aborted on the page, but it would be pretty
    // bad if old requests went to the new page, so let's make double sure
    self.browser.http_client.abort();
    self.removePage();

    const page = self.createPage() catch |err| {
        log.err(.browser, "queued navigation page error", .{
            .err = err,
            .url = qn.url,
        });
        return err;
    };

    page.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued navigation error", .{ .err = err, .url = qn.url });
        return err;
    };
}

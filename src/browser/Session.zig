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

const log = @import("../log.zig");

const js = @import("js/js.zig");
const storage = @import("webapi/storage/storage.zig");

const Page = @import("Page.zig");
const Browser = @import("Browser.zig");

const Allocator = std.mem.Allocator;
const NavigateOpts = Page.NavigateOpts;

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
cookie_jar: storage.Jar,
storage_shed: storage.Shed,

page: ?*Page = null,

// If the current page want to navigate to a new page
//  (form submit, link click, top.location = xxx)
// the details are stored here so that, on the next call to session.wait
// we can destroy the current page and start a new one.
queued_navigation: ?QueuedNavigation,

pub fn init(self: *Session, browser: *Browser) !void {
    var executor = try browser.env.newExecutionWorld();
    errdefer executor.deinit();

    const allocator = browser.app.allocator;
    self.* = .{
        .browser = browser,
        .executor = executor,
        .storage_shed = .{},
        .queued_navigation = null,
        .arena = browser.session_arena.allocator(),
        .cookie_jar = storage.Jar.init(allocator),
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
    std.debug.assert(self.page == null);

    const page_arena = &self.browser.page_arena;
    _ = page_arena.reset(.{ .retain_with_limit = 1 * 1024 * 1024 });

    self.page = try Page.init(page_arena.allocator(), self.browser.call_arena.allocator(), self);
    const page = self.page.?;

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

    self.page.?.deinit();
    self.page = null;

    log.debug(.browser, "remove page", .{});
}

pub fn currentPage(self: *Session) ?*Page {
    return self.page orelse return null;
}

pub const WaitResult = enum {
    done,
    no_page,
    extra_socket,
};

pub fn wait(self: *Session, wait_ms: u32) WaitResult {
    _ = self.processQueuedNavigation() catch {
        // There was an error processing the queue navigation. This already
        // logged the error, just return.
        return .done;
    };

    if (self.page) |page| {
        return page.wait(wait_ms);
    }
    return .no_page;
}

pub fn fetchWait(self: *Session, wait_ms: u32) void {
    while (true) {
        const page = self.page orelse return;
        _ = page.wait(wait_ms);
        const navigated = self.processQueuedNavigation() catch {
            // There was an error processing the queue navigation. This already
            // logged the error, just return.
            return;
        };

        if (navigated == false) {
            return;
        }
    }
}

fn processQueuedNavigation(self: *Session) !bool {
    const qn = self.queued_navigation orelse return false;
    // This was already aborted on the page, but it would be pretty
    // bad if old requests went to the new page, so let's make double sure
    self.browser.http_client.abort();

    // Page.navigateFromWebAPI terminatedExecution. If we don't resume
    // it before doing a shutdown we'll get an error.
    self.executor.resumeExecution();
    self.removePage();
    self.queued_navigation = null;

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

    return true;
}

const QueuedNavigation = struct {
    url: [:0]const u8,
    opts: NavigateOpts,
};

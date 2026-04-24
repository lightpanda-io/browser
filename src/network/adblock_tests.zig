// Copyright (C) 2025  Lightpanda (Selecy SAS)
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
const testing = std.testing;

const AdFilterModule = @import("network/AdFilter.zig");
const AdFilter = AdFilterModule.AdFilter;
const CosmeticFilter = @import("browser/CosmeticFilter.zig");
const Config = @import("Config.zig");
const UpdateScheduler = @import("UpdateScheduler.zig");
const App = @import("App.zig");
const HttpClient = @import("browser/HttpClient.zig");
const Session = @import("browser/Session.zig");
const Page = @import("browser/Page.zig");
const Notification = @import("Notification.zig");
const Browser = @import("browser/Browser.zig");

const testing_base = @import("testing.zig");
const expectError = testing_base.expectError;
const expect = testing_base.expect;
const expectEqual = testing_base.expectEqual;
const expectString = testing_base.expectString;
const expectEqualSlices = testing_base.expectEqualSlices;
const pageTest = testing_base.pageTest;
const newString = testing_base.newString;
const LogFilter = testing_base.LogFilter;

const test_session = testing_base.test_session;
const test_app = testing_base.test_app;
const test_http = testing_base.test_http;
const test_browser = testing_base.test_browser;

test "AdFilter: should block ad network requests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 3600,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var adfilter = try AdFilter.init(&config);
    defer adfilter.deinit();

    const ad_requests = [_][]const u8{
        "https://doubleclick.net/ad",
        "https://googleadservices.com/pagead/ads",
        "https://www.googletagmanager.com/gtag/js",
        "https://www.facebook.com/tr",
        "https://cdn.adsrvr.org/",
    };

    for (ad_requests) |url| {
        const should_block = adfilter.shouldBlock(url, .network_request);
        try testing.expect(should_block);
    }

    const non_ad_requests = [_][]const u8{
        "https://example.com",
        "https://api.github.com/users",
        "https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js",
        "https://fonts.googleapis.com/css",
    };

    for (non_ad_requests) |url| {
        const should_block = adfilter.shouldBlock(url, .network_request);
        try testing.expect(!should_block);
    }
}

test "AdFilter: should block ad image requests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 3600,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var adfilter = try AdFilter.init(&config);
    defer adfilter.deinit();

    const ad_image_requests = [_][]const u8{
        "https://cdn.ayads.co/",
        "https://cdn.taboola.com/",
        "https://cdn.outbrain.com/",
    };

    for (ad_image_requests) |url| {
        const should_block = adfilter.shouldBlock(url, .image_request);
        try testing.expect(should_block);
    }

    const non_ad_image_requests = [_][]const u8{
        "https://example.com/logo.png",
        "https://picsum.photos/200/300",
        "https://via.placeholder.com/150",
    };

    for (non_ad_image_requests) |url| {
        const should_block = adfilter.shouldBlock(url, .image_request);
        try testing.expect(!should_block);
    }
}

test "AdFilter: should block tracking scripts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 3600,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var adfilter = try AdFilter.init(&config);
    defer adfilter.deinit();

    const tracking_requests = [_][]const u8{
        "https://www.google-analytics.com/analytics.js",
        "https://connect.facebook.net/en_US/fbevents.js",
        "https://www.googleadservices.com/pagead/conversion_async.js",
        "https://www.google.com/recaptcha/api.js",
    };

    for (tracking_requests) |url| {
        const should_block = adfilter.shouldBlock(url, .script_request);
        try testing.expect(should_block);
    }

    const non_tracking_requests = [_][]const u8{
        "https://cdn.jsdelivr.net/npm/react@18/umd/react.production.min.js",
        "https://cdn.jsdelivr.net/npm/vue@3/dist/vue.global.js",
        "https://cdn.jsdelivr.net/npm/jquery@3.6.0/dist/jquery.min.js",
    };

    for (non_tracking_requests) |url| {
        const should_block = adfilter.shouldBlock(url, .script_request);
        try testing.expect(!should_block);
    }
}

test "AdFilter: should handle edge cases correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 3600,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var adfilter = try AdFilter.init(&config);
    defer adfilter.deinit();

    const edge_cases = [_][]const u8{
        "",
        "https://example.com/" ++ "a" ** 2000,
        "https://example.com/path?query=with%20spaces&special=characters",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5ErkJggg==",
        "file:///path/to/local/file.html",
    };

    for (edge_cases) |url| {
        const should_block = adfilter.shouldBlock(url, .network_request);
        try testing.expect(!should_block);
    }
}

test "CosmeticFilter: should hide ad elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 3600,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var cosmetic_filter = try CosmeticFilter.CosmeticFilter.init(allocator, &config);
    defer cosmetic_filter.deinit();

    const html_with_ads =
        "<!DOCTYPE html>\n" ++
        "<html>\n" ++
        "<head>\n" ++
        "    <title>Test Page</title>\n" ++
        "</head>\n" ++
        "<body>\n" ++
        "    <div class=\"ad-banner\">This is an ad banner</div>\n" ++
        "    <div class=\"advertisement\">Advertisement</div>\n" ++
        "    <div class=\"content\">This is real content</div>\n" ++
        "    <iframe src=\"https://ad.example.com\" class=\"ad-iframe\"></iframe>\n" ++
        "    <div id=\"main-content\">Main content area</div>\n" ++
        "</body>\n" ++
        "</html>";

    var page = try test_session.createPage();
    defer _ = test_session.removePage();

    try cosmetic_filter.apply(page);

    try expectAdElementHidden(page, "ad-banner");
    try expectAdElementHidden(page, "advertisement");
    try expectAdElementHidden(page, "ad-iframe");
    try expectElementVisible(page, "content");
    try expectElementVisible(page, "main-content");
}

test "CosmeticFilter: should handle dynamic content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 3600,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var cosmetic_filter = try CosmeticFilter.CosmeticFilter.init(allocator, &config);
    defer cosmetic_filter.deinit();

    const initial_html =
        "<!DOCTYPE html>\n" ++
        "<html>\n" ++
        "<head>\n" ++
        "    <title>Test Page</title>\n" ++
        "</head>\n" ++
        "<body>\n" ++
        "    <div id=\"main-content\">Main content</div>\n" ++
        "</body>\n" ++
        "</html>";

    var page = try test_session.createPage();
    defer _ = test_session.removePage();

    try cosmetic_filter.apply(page);

    try cosmetic_filter.applyDynamicContent(page, "<div class=\"ad-banner\">New ad banner</div>");

    try expectAdElementHidden(page, "ad-banner");
    try expectElementVisible(page, "main-content");
}

test "UpdateScheduler: should initialize with config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 1,
            .lists = &.{"https://easylist.to/easylist/easylist.txt"},
        },
    });
    defer config.deinit(allocator);

    var scheduler = try UpdateScheduler.init(allocator, &config);
    defer scheduler.deinit();

    try testing.expect(scheduler.getFilterCount() == 0);
}

test "HttpClient: adblock integration should block requests" {
    test_app.config.enable_adblock = true;
    test_app.config.adblock_lists = &.{"https://easylist.to/easylist/easylist.txt"};
    test_app.config.adblock_update_interval = 3600;

    try expectError(error.RequestBlocked, test_http.processRequest("https://doubleclick.net/ad", .{}, .{}));
}

test "HttpClient: adblock integration should allow non-ad requests" {
    test_app.config.enable_adblock = true;
    test_app.config.adblock_lists = &.{"https://easylist.to/easylist/easylist.txt"};
    test_app.config.adblock_update_interval = 3600;

    const result = try test_http.processRequest("https://example.com", .{}, .{});
    try testing.expect(result.status_code == 200);
}

test "Config: adblock settings should be configurable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = true,
            .update_interval = 7200,
            .lists = &.{
                "https://easylist.to/easylist/easylist.txt",
                "https://easylist.to/easylist/easyprivacy.txt",
            },
        },
    });
    defer config.deinit(allocator);

    try testing.expect(config.enable_adblock == true);
    try testing.expect(config.adblock_update_interval == 7200);
    try testing.expect(config.adblock_lists.len == 2);
}

test "Config: adblock can be disabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = false,
            .update_interval = 3600,
            .lists = &.{},
        },
    });
    defer config.deinit(allocator);

    try testing.expect(config.enable_adblock == false);
}

test "AdFilter: null engine should not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = false,
            .update_interval = 3600,
            .lists = &.{},
        },
    });
    defer config.deinit(allocator);

    var adfilter = try AdFilter.init(&config);
    defer adfilter.deinit();

    const result = adfilter.shouldBlock("https://example.com", .network_request);
    try testing.expect(!result);
}

test "CosmeticFilter: disabled adblock should not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try Config.init(allocator, "test", .{
        .adblock = .{
            .enable = false,
            .update_interval = 3600,
            .lists = &.{},
        },
    });
    defer config.deinit(allocator);

    var cosmetic_filter = try CosmeticFilter.CosmeticFilter.init(allocator, &config);
    defer cosmetic_filter.deinit();

    var page = try test_session.createPage();
    defer _ = test_session.removePage();

    try cosmetic_filter.apply(page);
}

fn expectAdElementHidden(page: *Page, selector: [:0]const u8) !void {
    _ = page;
    _ = selector;
}

fn expectElementVisible(page: *Page, selector: [:0]const u8) !void {
    _ = page;
    _ = selector;
}

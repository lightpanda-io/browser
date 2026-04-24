const std = @import("std");
const testing = std.testing;

const Config = @import("../Config.zig");
const AdFilterModule = @import("AdFilter.zig");
const AdFilter = AdFilterModule.AdFilter;
const RequestType = AdFilterModule.RequestType;

const network_rules =
    \\||ads.example.test^
    \\||tracker.example.test^$script
    \\@@||ads.example.test/allowed.js
;

const image_rules =
    \\||images.example.test^$image
;

const replacement_rules =
    \\||replacement.example.test^
;

const replacement_image_rules =
    \\||media.example.test^$image
;

const cosmetic_rules =
    \\example.test##.ad-banner
    \\example.test##.sponsored
;

const easylist_url = "https://easylist.to/easylist/easylist.txt";
const easyprivacy_url = "https://easylist.to/easylist/easyprivacy.txt";

fn initFilter(lists: []const []const u8) !AdFilter {
    const config = Config.AdblockConfig{
        .enable = true,
        .lists = lists,
    };
    return AdFilter.init(&config);
}

fn requireLiveAdblockTests() !void {
    const value = std.process.getEnvVarOwned(testing.allocator, "LIGHTPANDA_ADBLOCK_LIVE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(value);

    if (!std.ascii.eqlIgnoreCase(value, "true")) {
        return error.SkipZigTest;
    }
}

fn fetchFilterList(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) {
        return error.UnexpectedHttpStatus;
    }

    return try body.toOwnedSlice();
}

test "AdFilter: loads all configured filter lists" {
    var filter = try initFilter(&.{ network_rules, image_rules });
    defer filter.deinit();

    try testing.expect(filter.shouldBlock(
        "https://ads.example.test/banner.js",
        "https://page.example.test/",
        .script,
    ));
    try testing.expect(filter.shouldBlock(
        "https://images.example.test/ad.png",
        "https://page.example.test/",
        .image,
    ));
    try testing.expect(!filter.shouldBlock(
        "https://content.example.test/app.js",
        "https://page.example.test/",
        .script,
    ));
}

test "AdFilter: delegates request type and exception matching to adblock engine" {
    var filter = try initFilter(&.{network_rules});
    defer filter.deinit();

    try testing.expect(filter.shouldBlock(
        "https://tracker.example.test/pixel.js",
        "https://page.example.test/",
        .script,
    ));
    try testing.expect(!filter.shouldBlock(
        "https://tracker.example.test/pixel.png",
        "https://page.example.test/",
        .image,
    ));
    try testing.expect(!filter.shouldBlock(
        "https://ads.example.test/allowed.js",
        "https://page.example.test/",
        .script,
    ));
}

test "AdFilter: replaces filter lists atomically through FFI-owned state" {
    var filter = try initFilter(&.{ network_rules, image_rules });
    defer filter.deinit();

    try filter.replaceFilterLists(&.{ replacement_rules, replacement_image_rules });

    try testing.expect(!filter.shouldBlock(
        "https://ads.example.test/banner.js",
        "https://page.example.test/",
        .script,
    ));
    try testing.expect(filter.shouldBlock(
        "https://replacement.example.test/banner.js",
        "https://page.example.test/",
        .script,
    ));
    try testing.expect(filter.shouldBlock(
        "https://media.example.test/ad.png",
        "https://page.example.test/",
        .image,
    ));
}

test "AdFilter: copies and frees cosmetic filter JSON returned by FFI" {
    var filter = try initFilter(&.{cosmetic_rules});
    defer filter.deinit();

    const json = (try filter.getCosmeticFilters(testing.allocator, "https://example.test/article")) orelse
        return error.ExpectedCosmeticFilters;
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, ".ad-banner") != null);
    try testing.expect(std.mem.indexOf(u8, json, ".sponsored") != null);
}

test "AdFilter: disabled config has no engine and does not block" {
    const config = Config.AdblockConfig{ .enable = false };
    var filter = try AdFilter.init(&config);
    defer filter.deinit();

    try testing.expect(!filter.shouldBlock(
        "https://ads.example.test/banner.js",
        "https://page.example.test/",
        RequestType.script,
    ));
}

test "AdFilter live: EasyList and EasyPrivacy block representative requests" {
    try requireLiveAdblockTests();

    const easylist = try fetchFilterList(testing.allocator, easylist_url);
    defer testing.allocator.free(easylist);
    const easyprivacy = try fetchFilterList(testing.allocator, easyprivacy_url);
    defer testing.allocator.free(easyprivacy);

    var filter = try initFilter(&.{ easylist, easyprivacy });
    defer filter.deinit();

    try testing.expect(filter.shouldBlock(
        "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
        "https://www.example.com/",
        .script,
    ));
    try testing.expect(filter.shouldBlock(
        "https://www.google-analytics.com/analytics.js",
        "https://www.example.com/",
        .script,
    ));
    try testing.expect(filter.shouldBlock(
        "https://pagead2.googlesyndication.com/pagead/imgad?id=123",
        "https://www.example.com/",
        .image,
    ));
    try testing.expect(!filter.shouldBlock(
        "https://www.example.com/assets/application.js",
        "https://www.example.com/",
        .script,
    ));
}

test "AdFilter live: replacing real lists keeps the new complete set active" {
    try requireLiveAdblockTests();

    const easylist = try fetchFilterList(testing.allocator, easylist_url);
    defer testing.allocator.free(easylist);
    const easyprivacy = try fetchFilterList(testing.allocator, easyprivacy_url);
    defer testing.allocator.free(easyprivacy);

    var filter = try initFilter(&.{easylist});
    defer filter.deinit();

    try filter.replaceFilterLists(&.{ easylist, easyprivacy });

    try testing.expect(filter.shouldBlock(
        "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
        "https://www.example.com/",
        .script,
    ));
    try testing.expect(filter.shouldBlock(
        "https://www.google-analytics.com/analytics.js",
        "https://www.example.com/",
        .script,
    ));
}

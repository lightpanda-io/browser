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
const lp = @import("lightpanda");
const CDP = @import("../CDP.zig");

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        getMetrics,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .disable => return cmd.sendResult(null, .{}),
        .getMetrics => return getMetrics(cmd),
    }
}

const Metric = struct {
    name: []const u8,
    value: f64,
};

// https://chromedevtools.github.io/devtools-protocol/tot/Performance/#method-getMetrics
// Puppeteer's page.metrics() sends this. Only the metrics that have a real
// counterpart here are reported; Puppeteer keeps whichever of its known names
// it receives. Layout, style and script timings have no equivalent without a
// renderer, so they are left out rather than reported as zero.
fn getMetrics(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const stats = bc.session.browser.env.isolate.getHeapStatistics();
    const now_us: f64 = @floatFromInt(lp.datetime.microTimestamp(.boot));

    const metrics = [_]Metric{
        .{ .name = "Timestamp", .value = now_us / std.time.us_per_s },
        .{ .name = "JSHeapUsedSize", .value = @floatFromInt(stats.used_heap_size) },
        .{ .name = "JSHeapTotalSize", .value = @floatFromInt(stats.total_heap_size) },
    };
    return cmd.sendResult(.{ .metrics = &metrics }, .{});
}

const testing = @import("../testing.zig");
test "cdp.performance: getMetrics" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Performance.getMetrics" });
    try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 1 });

    _ = try ctx.loadBrowserContext(.{ .id = "BID-PERF", .url = "hi.html" });
    try ctx.processMessage(.{ .id = 2, .method = "Performance.enable" });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Performance.getMetrics" });
    var i: usize = 0;
    const result = blk: while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const id = msg.object.get("id") orelse continue;
        if (id == .integer and id.integer == 3) break :blk msg.object.get("result").?;
    } else return error.NoResult;

    const metrics = result.object.get("metrics").?.array.items;
    try testing.expectEqual(3, metrics.len);

    var seen: usize = 0;
    for (metrics) |m| {
        const name = m.object.get("name").?.string;
        const value: f64 = switch (m.object.get("value").?) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.UnexpectedMetricValue,
        };
        try testing.expect(value > 0);
        for ([_][]const u8{ "Timestamp", "JSHeapUsedSize", "JSHeapTotalSize" }) |expected| {
            if (std.mem.eql(u8, name, expected)) seen += 1;
        }
    }
    try testing.expectEqual(3, seen);
}

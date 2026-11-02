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
const Frame = @import("../../../browser/Frame.zig");

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
// renderer. Chrome's Nodes and Documents count every live instance (detached
// nodes, DOMParser documents, ...), which we don't track, so they're left out
// too rather than undercounted.
fn getMetrics(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const stats = bc.session.browser.env.isolate.getHeapStatistics();
    const now_us: f64 = @floatFromInt(lp.datetime.microTimestamp(.boot));

    var buf: [5]Metric = undefined;
    var metrics: std.ArrayList(Metric) = .initBuffer(&buf);
    metrics.appendAssumeCapacity(.{ .name = "Timestamp", .value = now_us / std.time.us_per_s });

    if (bc.mainPage()) |page| {
        var frames = countFrames(&page.frame);
        for (page.popups.items) |popup| {
            frames += countFrames(popup);
        }
        metrics.appendAssumeCapacity(.{ .name = "Frames", .value = @floatFromInt(frames) });
        metrics.appendAssumeCapacity(.{ .name = "JSEventListeners", .value = @floatFromInt(page.event_listeners.listenerCount()) });
    }

    metrics.appendAssumeCapacity(.{ .name = "JSHeapUsedSize", .value = @floatFromInt(stats.used_heap_size) });
    metrics.appendAssumeCapacity(.{ .name = "JSHeapTotalSize", .value = @floatFromInt(stats.total_heap_size) });
    return cmd.sendResult(.{ .metrics = metrics.items }, .{});
}

fn countFrames(frame: *const Frame) usize {
    var count: usize = 1;
    for (frame.child_frames.items) |child| {
        count += countFrames(child);
    }
    return count;
}

const testing = @import("../testing.zig");
const js = @import("../../../browser/js/js.zig");

test "cdp.performance: getMetrics" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Performance.getMetrics" });
    try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 1 });

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-PERF", .url = "hi.html" });
    try ctx.processMessage(.{ .id = 2, .method = "Performance.enable" });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const before = try getMetricsResult(&ctx, 3);
    try testing.expectEqual(5, before.len);
    for ([_][]const u8{ "Timestamp", "JSHeapUsedSize", "JSHeapTotalSize" }) |name| {
        try testing.expect(findMetric(before, name) > 0);
    }
    try testing.expectEqual(1, findMetric(before, "Frames"));

    {
        const frame = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(
            \\document.body.appendChild(document.createElement('iframe'));
            \\const h = () => {};
            \\window.addEventListener('perf-a', h);
            \\window.addEventListener('perf-a', h); // duplicate, not added
            \\document.addEventListener('perf-b', () => {});
        , null);
    }
    try testing.waitForPage(bc);

    const after = try getMetricsResult(&ctx, 4);
    try testing.expectEqual(2, findMetric(after, "Frames"));
    try testing.expectEqual(findMetric(before, "JSEventListeners") + 2, findMetric(after, "JSEventListeners"));
}

const TestMetric = struct { name: []const u8, value: f64 };

fn getMetricsResult(ctx: anytype, id: i64) ![]const TestMetric {
    try ctx.processMessage(.{ .id = id, .method = "Performance.getMetrics" });
    var i: usize = 0;
    const result = blk: while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const msg_id = msg.object.get("id") orelse continue;
        if (msg_id == .integer and msg_id.integer == id) break :blk msg.object.get("result").?;
    } else return error.NoResult;

    const items = result.object.get("metrics").?.array.items;
    const metrics = try testing.arena_allocator.alloc(TestMetric, items.len);
    for (items, metrics) |item, *m| {
        m.* = .{
            .name = item.object.get("name").?.string,
            .value = switch (item.object.get("value").?) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return error.UnexpectedMetricValue,
            },
        };
    }
    return metrics;
}

fn findMetric(metrics: []const TestMetric, name: []const u8) f64 {
    for (metrics) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.value;
    }
    return -1;
}

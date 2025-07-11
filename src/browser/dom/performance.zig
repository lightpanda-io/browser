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

const parser = @import("../netsurf.zig");
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

pub const Interfaces = .{
    Performance,
    PerformanceEntry,
    PerformanceMark,
};

const MarkOptions = struct {
    detail: ?Env.JsObject = null,
    start_time: ?f64 = null,
};

// https://developer.mozilla.org/en-US/docs/Web/API/Performance
pub const Performance = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .performance },

    time_origin: std.time.Timer,
    // if (Window.crossOriginIsolated) -> Resolution in isolated contexts:       5 microseconds
    // else                            -> Resolution in non-isolated contexts: 100 microseconds
    const ms_resolution = 100;

    fn limitedResolutionMs(nanoseconds: u64) f64 {
        const elapsed_at_resolution = ((nanoseconds / std.time.ns_per_us) + ms_resolution / 2) / ms_resolution * ms_resolution;
        const elapsed = @as(f64, @floatFromInt(elapsed_at_resolution));
        return elapsed / @as(f64, std.time.us_per_ms);
    }

    pub fn get_timeOrigin(self: *const Performance) f64 {
        const is_posix = switch (@import("builtin").os.tag) { // From std.time.zig L125
            .windows, .uefi, .wasi => false,
            else => true,
        };
        const zero = std.time.Instant{ .timestamp = if (!is_posix) 0 else .{ .sec = 0, .nsec = 0 } };
        const started = self.time_origin.started.since(zero);
        return limitedResolutionMs(started);
    }

    pub fn _now(self: *Performance) f64 {
        return limitedResolutionMs(self.time_origin.read());
    }

    pub fn _mark(_: *Performance, name: []const u8, _options: ?MarkOptions, page: *Page) !PerformanceMark {
        const mark: PerformanceMark = try .constructor(name, _options, page);
        // TODO: Should store this in an entries list
        return mark;
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceEntry
pub const PerformanceEntry = struct {
    const PerformanceEntryType = enum {
        element,
        event,
        first_input,
        largest_contentful_paint,
        layout_shift,
        long_animation_frame,
        longtask,
        mark,
        measure,
        navigation,
        paint,
        resource,
        taskattribution,
        visibility_state,

        pub fn toString(self: PerformanceEntryType) []const u8 {
            return switch (self) {
                .first_input => "first-input",
                .largest_contentful_paint => "largest-contentful-paint",
                .layout_shift => "layout-shift",
                .long_animation_frame => "long-animation-frame",
                .visibility_state => "visibility-state",
                else => @tagName(self),
            };
        }
    };

    duration: f64 = 0.0,
    entry_type: PerformanceEntryType,
    name: []const u8,
    start_time: f64 = 0.0,

    pub fn get_duration(self: *const PerformanceEntry) f64 {
        return self.duration;
    }

    pub fn get_entryType(self: *const PerformanceEntry) PerformanceEntryType {
        return self.entry_type;
    }

    pub fn get_name(self: *const PerformanceEntry) []const u8 {
        return self.name;
    }

    pub fn get_startTime(self: *const PerformanceEntry) f64 {
        return self.start_time;
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceMark
pub const PerformanceMark = struct {
    pub const prototype = *PerformanceEntry;

    proto: PerformanceEntry,
    detail: ?Env.JsObject,

    pub fn constructor(name: []const u8, _options: ?MarkOptions, page: *Page) !PerformanceMark {
        const perf = &page.window.performance;

        const options = _options orelse MarkOptions{};
        const start_time = options.start_time orelse perf._now();
        const detail = if (options.detail) |d| try d.persist() else null;

        if (start_time < 0.0) {
            return error.TypeError;
        }

        const duped_name = try page.arena.dupe(u8, name);
        const proto = PerformanceEntry{ .name = duped_name, .entry_type = .mark, .start_time = start_time };

        return .{ .proto = proto, .detail = detail };
    }

    pub fn get_detail(self: *const PerformanceMark) ?Env.JsObject {
        return self.detail;
    }
};

const testing = @import("./../../testing.zig");

test "Performance: get_timeOrigin" {
    var perf = Performance{ .time_origin = try std.time.Timer.start() };
    const time_origin = perf.get_timeOrigin();
    try testing.expect(time_origin >= 0);

    // Check resolution
    try testing.expectDelta(@rem(time_origin * std.time.us_per_ms, 100.0), 0.0, 0.1);
}

test "Performance: now" {
    var perf = Performance{ .time_origin = try std.time.Timer.start() };

    // Monotonically increasing
    var now = perf._now();
    while (now <= 0) { // Loop for now to not be 0
        try testing.expectEqual(now, 0);
        now = perf._now();
    }
    // Check resolution
    try testing.expectDelta(@rem(now * std.time.us_per_ms, 100.0), 0.0, 0.1);

    var after = perf._now();
    while (after <= now) { // Loop untill after > now
        try testing.expectEqual(after, now);
        after = perf._now();
    }
    // Check resolution
    try testing.expectDelta(@rem(after * std.time.us_per_ms, 100.0), 0.0, 0.1);
}

test "Browser.Performance.Mark" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let performance = window.performance", "undefined" },
        .{ "performance instanceof Performance", "true" },
        .{ "let mark = performance.mark(\"start\")", "undefined" },
        .{ "mark instanceof PerformanceMark", "true" },
        .{ "mark.name", "start" },
        .{ "mark.entryType", "mark" },
        .{ "mark.duration", "0" },
        .{ "mark.detail", "null" },
    }, .{});
}

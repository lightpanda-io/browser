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

// https://developer.mozilla.org/en-US/docs/Web/API/Performance
pub const Performance = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{},

    time_origin: std.time.Timer,
    // if (Window.crossOriginIsolated) -> Resolution in isolated contexts:       5 microseconds
    // else                            -> Resolution in non-isolated contexts: 100 microseconds
    const ms_resolution = 100;

    fn limited_resolution_ms(nanoseconds: u64) f64 {
        const elapsed_at_resolution = ((nanoseconds / std.time.ns_per_ms) + ms_resolution / 2) / ms_resolution * ms_resolution;
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
        return limited_resolution_ms(started);
    }

    pub fn _now(self: *Performance) f64 {
        return limited_resolution_ms(self.time_origin.read());
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
        try testing.expect(now == 0);
        now = perf._now();
    }
    // Check resolution
    try testing.expectDelta(@rem(now * std.time.us_per_ms, 100.0), 0.0, 0.1);

    var after = perf._now();
    while (after <= now) { // Loop untill after > now
        try testing.expect(after == now);
        after = perf._now();
    }
    // Check resolution
    try testing.expectDelta(@rem(after * std.time.us_per_ms, 100.0), 0.0, 0.1);
}

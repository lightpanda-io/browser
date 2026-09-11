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

//! The page's clock: timers, performance.now, event and resource timestamps.
//! Infrastructure (watchdog, HTTP, rate limiter, server) stays on the boot
//! clock. Process-wide like V8's platform clock; browser thread only; never
//! rewinds.

const std = @import("std");
const lp = @import("lightpanda");

const Platform = @import("js/Platform.zig");

var offset_us: u64 = 0;

pub fn milli() u64 {
    return lp.datetime.milliTimestamp(.boot) + offset_us / std.time.us_per_ms;
}

pub fn micro() u64 {
    return lp.datetime.microTimestamp(.boot) + offset_us;
}

pub fn advance(platform: Platform, ms: u32) void {
    offset_us += @as(u64, ms) * std.time.us_per_ms;
    platform.setClockOffsetMillis(@floatFromInt(offset_us / std.time.us_per_ms));
}

pub const Budget = struct {
    per_navigation_ms: u32,
    remaining_ms: u32,

    pub fn init(ms: u32) Budget {
        return .{ .per_navigation_ms = ms, .remaining_ms = ms };
    }

    pub fn reset(self: *Budget) void {
        self.remaining_ms = self.per_navigation_ms;
    }

    pub fn grant(self: *Budget, wanted_ms: u64) u32 {
        const granted: u32 = @intCast(@min(wanted_ms, self.remaining_ms));
        self.remaining_ms -= granted;
        return granted;
    }
};

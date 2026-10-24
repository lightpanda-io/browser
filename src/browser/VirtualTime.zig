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

var offset_ms: u64 = 0;

pub fn milli() u64 {
    return lp.datetime.milliTimestamp(.boot) + offset_ms;
}

pub fn micro() u64 {
    return lp.datetime.microTimestamp(.boot) + offset_ms * std.time.us_per_ms;
}

pub fn advance(platform: Platform, ms: u32) void {
    offset_ms += ms;
    platform.setClockOffsetMillis(@floatFromInt(offset_ms));
}

pub const Budget = struct {
    remaining_ms: u32,
    // --virtual-time-budget-ms refills on each navigation; an
    // Emulation.setVirtualTimePolicy budget is spent once, like Chrome's, and
    // a page with nothing scheduled runs it out so virtualTimeBudgetExpired
    // still fires.
    refill: union(enum) { per_navigation: u32, expires, unbounded },
    skip_during_fetches: bool = false,

    pub fn init(ms: u32) Budget {
        return .{ .remaining_ms = ms, .refill = .{ .per_navigation = ms } };
    }

    pub fn reset(self: *Budget) void {
        switch (self.refill) {
            .per_navigation => |ms| self.remaining_ms = ms,
            .expires, .unbounded => {},
        }
    }

    pub fn grant(self: *Budget, wanted_ms: u64) u32 {
        if (self.refill == .unbounded) {
            return @intCast(@min(wanted_ms, std.math.maxInt(u32)));
        }
        const granted: u32 = @intCast(@min(wanted_ms, self.remaining_ms));
        self.remaining_ms -= granted;
        return granted;
    }
};

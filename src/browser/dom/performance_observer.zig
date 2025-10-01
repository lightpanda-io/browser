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
const js = @import("../js/js.zig");

const PerformanceEntry = @import("performance.zig").PerformanceEntry;

// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceObserver
pub const PerformanceObserver = struct {
    pub const _supportedEntryTypes = [0][]const u8{};

    pub fn constructor(cbk: js.Function) PerformanceObserver {
        _ = cbk;
        return .{};
    }

    pub fn _observe(self: *const PerformanceObserver, options_: ?Options) void {
        _ = self;
        _ = options_;
        return;
    }

    pub fn _disconnect(self: *PerformanceObserver) void {
        _ = self;
    }

    pub fn _takeRecords(_: *const PerformanceObserver) []PerformanceEntry {
        return &[_]PerformanceEntry{};
    }
};

const Options = struct {
    buffered: ?bool = null,
    durationThreshold: ?f64 = null,
    entryTypes: ?[]const []const u8 = null,
    type: ?[]const u8 = null,
};

const testing = @import("../../testing.zig");
test "Browser: DOM.PerformanceObserver" {
    try testing.htmlRunner("dom/performance_observer.html");
}

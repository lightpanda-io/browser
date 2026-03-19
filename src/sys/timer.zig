// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

pub const Timer = struct {
    kind: Kind = .mock,
    mock_now_ns: u64 = 0,

    pub const Kind = enum {
        hosted,
        mock,
    };

    pub fn hosted() Timer {
        return .{ .kind = .hosted };
    }

    pub fn mock(start_ns: u64) Timer {
        return .{ .kind = .mock, .mock_now_ns = start_ns };
    }

    pub fn now(self: *const Timer) u64 {
        return switch (self.kind) {
            .hosted => @as(u64, @intCast(std.time.nanoTimestamp())),
            .mock => self.mock_now_ns,
        };
    }

    pub fn advance(self: *Timer, delta_ns: u64) void {
        if (self.kind == .mock) {
            self.mock_now_ns += delta_ns;
        }
    }

    pub fn sleep(self: *Timer, delta_ns: u64) void {
        switch (self.kind) {
            .hosted => std.Thread.sleep(delta_ns),
            .mock => self.mock_now_ns += delta_ns,
        }
    }
};

test "timer mock advances deterministically" {
    var timer = Timer.mock(12);
    try std.testing.expectEqual(@as(u64, 12), timer.now());
    timer.advance(8);
    try std.testing.expectEqual(@as(u64, 20), timer.now());
    timer.sleep(5);
    try std.testing.expectEqual(@as(u64, 25), timer.now());
}

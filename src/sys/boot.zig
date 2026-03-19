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
const serial_log = @import("serial_log.zig");

const Allocator = std.mem.Allocator;

pub const BootState = enum {
    cold,
    banner,
    running,
    failed,
    stopped,
};

pub const Boot = struct {
    state: BootState = .cold,
    last_error: ?[]u8 = null,

    pub fn init() Boot {
        return .{};
    }

    pub fn deinit(self: *Boot, allocator: Allocator) void {
        if (self.last_error) |err| {
            allocator.free(err);
            self.last_error = null;
        }
        self.* = undefined;
    }

    pub fn start(self: *Boot) void {
        self.state = .banner;
    }

    pub fn markRunning(self: *Boot) void {
        self.state = .running;
    }

    pub fn fail(self: *Boot, allocator: Allocator, log: *serial_log.SerialLog, message: []const u8) !void {
        self.state = .failed;
        if (self.last_error) |err| {
            allocator.free(err);
        }
        self.last_error = try allocator.dupe(u8, message);
        try log.appendLine(allocator, message);
    }

    pub fn shutdown(self: *Boot) void {
        self.state = .stopped;
    }

    pub fn reboot(self: *Boot) void {
        self.state = .cold;
    }
};

test "boot transitions record failures" {
    var boot = Boot.init();
    defer boot.deinit(std.testing.allocator);

    var log = serial_log.SerialLog.init();
    defer log.deinit(std.testing.allocator);

    boot.start();
    try std.testing.expectEqual(BootState.banner, boot.state);
    try boot.fail(std.testing.allocator, &log, "panic");
    try std.testing.expectEqual(BootState.failed, boot.state);
    try std.testing.expectEqualStrings("panic", boot.last_error.?);
    try std.testing.expectEqualStrings("panic", log.last().?);
}

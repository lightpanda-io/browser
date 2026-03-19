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

const Allocator = std.mem.Allocator;

pub const boot = @import("boot.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const input = @import("input.zig");
pub const net = @import("net.zig");
pub const serial_log = @import("serial_log.zig");
pub const storage = @import("storage.zig");
pub const timer = @import("timer.zig");

pub const Host = struct {
    allocator: Allocator,
    storage: storage.Storage = .{},
    framebuffer: framebuffer.Framebuffer = .{},
    input: input.Input = .{},
    timer: timer.Timer = .{},
    serial_log: serial_log.SerialLog = .{},
    net: net.Transport = .{},
    boot: boot.Boot = .{},

    pub fn initHosted(allocator: Allocator) Host {
        return .{
            .allocator = allocator,
            .storage = storage.Storage.hosted(),
            .framebuffer = .{},
            .input = .{},
            .timer = timer.Timer.hosted(),
            .serial_log = serial_log.SerialLog.init(),
            .net = net.Transport.hosted(),
            .boot = boot.Boot.init(),
        };
    }

    pub fn initMock(allocator: Allocator) Host {
        return .{
            .allocator = allocator,
            .storage = storage.Storage.mock(),
            .framebuffer = .{},
            .input = .{},
            .timer = timer.Timer.mock(0),
            .serial_log = serial_log.SerialLog.init(),
            .net = net.Transport.mock(),
            .boot = boot.Boot.init(),
        };
    }

    pub fn initForBuildClass(allocator: Allocator, bare_metal: bool) Host {
        return if (bare_metal) .{
            .allocator = allocator,
            .storage = storage.Storage.hosted(),
            .framebuffer = .{},
            .input = .{},
            .timer = timer.Timer.mock(0),
            .serial_log = serial_log.SerialLog.init(),
            .net = net.Transport.mock(),
            .boot = boot.Boot.init(),
        } else initHosted(allocator);
    }

    pub fn deinit(self: *Host) void {
        self.storage.deinit(self.allocator);
        self.framebuffer.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.serial_log.deinit(self.allocator);
        self.boot.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resolveProfileDir(self: *const Host, override_path: ?[]const u8) ?[]const u8 {
        return self.storage.resolveProfileDir(self.allocator, override_path);
    }

    pub fn resolveProfileFile(self: *const Host, profile_root: ?[]const u8, name: []const u8) ?[]const u8 {
        return self.storage.resolveProfileFile(self.allocator, profile_root, name);
    }

    pub fn resolveProfileSubdir(self: *const Host, profile_root: ?[]const u8, subdir: []const u8) ?[]const u8 {
        return self.storage.resolveProfileSubdir(self.allocator, profile_root, subdir);
    }

    pub fn writeFile(self: *Host, path: []const u8, data: []const u8) !void {
        try self.storage.writeFile(self.allocator, path, data);
    }

    pub fn readFile(self: *Host, path: []const u8) ![]u8 {
        return self.storage.readFile(self.allocator, path);
    }

    pub fn deleteFile(self: *Host, path: []const u8) !void {
        try self.storage.deleteFile(self.allocator, path);
    }

    pub fn logLine(self: *Host, line: []const u8) !void {
        try self.serial_log.appendLine(self.allocator, line);
    }

    pub fn panic(self: *Host, message: []const u8) !void {
        try self.boot.fail(self.allocator, &self.serial_log, message);
    }
};

test "host mock composes platform services" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    const profile = host.resolveProfileDir("tmp-host-mock-profile") orelse return error.TestExpected;
    defer std.testing.allocator.free(profile);

    try host.logLine("boot");
    try host.panic("panic");
    try std.testing.expectEqualStrings("panic", host.serial_log.last().?);
    try std.testing.expectEqual(boot.BootState.failed, host.boot.state);
}

test "host bare metal build class uses filesystem-backed storage" {
    var host = Host.initForBuildClass(std.testing.allocator, true);
    defer host.deinit();

    const rel_dir = "tmp-host-bare-metal-profile";
    std.fs.cwd().deleteTree(rel_dir) catch {};
    defer std.fs.cwd().deleteTree(rel_dir) catch {};

    const profile = host.resolveProfileDir(rel_dir) orelse return error.TestExpected;
    defer std.testing.allocator.free(profile);

    try std.testing.expectEqualStrings(rel_dir, profile);

    var dir = try std.fs.cwd().openDir(rel_dir, .{});
    defer dir.close();
}

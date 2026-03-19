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

const BrowserCommand = @import("BrowserCommand.zig").BrowserCommand;
const Display = @import("Display.zig");
const DisplayList = @import("../render/DisplayList.zig").DisplayList;

pub const BareMetalBackend = struct {
    page_count: u32 = 0,
    last_viewport_width: u32 = 0,
    last_viewport_height: u32 = 0,
    last_display_hash: u64 = 0,
    last_command_count: usize = 0,
    last_content_height: i32 = 0,
    last_title: []const u8 = &.{},
    last_url: []const u8 = &.{},

    pub fn init(_: anytype, width: u32, height: u32) @This() {
        return .{
            .last_viewport_width = width,
            .last_viewport_height = height,
        };
    }

    pub fn onPageCreated(self: *@This()) bool {
        self.page_count += 1;
        return true;
    }

    pub fn onPageRemoved(self: *@This()) bool {
        if (self.page_count > 0) {
            self.page_count -= 1;
        }
        return self.page_count == 0;
    }

    pub fn onViewportChanged(self: *@This(), width: u32, height: u32) void {
        self.last_viewport_width = width;
        self.last_viewport_height = height;
    }

    pub fn setNavigationState(_: *@This(), _: bool, _: bool, _: bool, _: i32) void {}
    pub fn setHistoryEntries(_: *@This(), _: []const []const u8, _: usize) void {}
    pub fn setDownloadEntries(_: *@This(), _: []const Display.DownloadEntry) void {}
    pub fn setTabEntries(_: *@This(), _: []const Display.TabEntry, _: usize) void {}
    pub fn setSettingsState(_: *@This(), _: Display.SettingsState) void {}
    pub fn setAppDataPath(_: *@This(), _: ?[]const u8) void {}
    pub fn setHttpRuntime(_: *@This(), _: *anyopaque) void {}
    pub fn setImageRequestCookieJar(_: *@This(), _: ?*anyopaque) void {}
    pub fn dispatchInput(_: *@This(), _: anytype) !void {}

    pub fn presentDocument(self: *@This(), title: []const u8, url: []const u8, _: []const u8) !void {
        self.last_title = title;
        self.last_url = url;
    }

    pub fn presentPageView(self: *@This(), title: []const u8, url: []const u8, _: []const u8, display_list: ?*const DisplayList) !void {
        self.last_title = title;
        self.last_url = url;
        if (display_list) |list| {
            var hasher = std.hash.Wyhash.init(0);
            list.hashInto(&hasher);
            self.last_display_hash = hasher.final();
            self.last_command_count = list.commands.items.len;
            self.last_content_height = list.content_height;
        } else {
            self.last_display_hash = 0;
            self.last_command_count = 0;
            self.last_content_height = 0;
        }
    }

    pub fn saveBitmap(_: *@This(), _: []const u8) bool {
        return false;
    }

    pub fn savePng(_: *@This(), _: []const u8) bool {
        return false;
    }

    pub fn chooseFiles(_: *@This(), _: []const u8, _: bool) ?Display.ChosenFiles {
        return null;
    }

    pub fn nextBrowserCommand(_: *@This()) ?BrowserCommand {
        return null;
    }

    pub fn userClosed(_: *const @This()) bool {
        return false;
    }

    pub fn deinit(_: *@This()) void {}
};

test "bare metal backend records display list summary" {
    var backend = BareMetalBackend.init(std.testing.allocator, 800, 600);
    try backend.presentDocument("title", "url", "body");
    try std.testing.expectEqual(@as(u32, 800), backend.last_viewport_width);
    try std.testing.expectEqualStrings("title", backend.last_title);
    try std.testing.expectEqualStrings("url", backend.last_url);
}

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

const Page = @import("../Page.zig");
const PopStateEvent = @import("event/PopStateEvent.zig");

const History = @This();

const ScrollRestoration = enum { auto, manual };

_scroll_restoration: ScrollRestoration = .auto,

pub fn getLength(_: *const History, page: *Page) u32 {
    return @intCast(page._session.navigation._entries.items.len);
}

pub fn getState(_: *const History, page: *Page) !?js.Value {
    if (page._session.navigation.getCurrentEntry()._state.value) |state| {
        const value = try page.js.parseJSON(state);
        return value;
    } else return null;
}

pub fn getScrollRestoration(self: *History) []const u8 {
    return @tagName(self._scroll_restoration);
}

pub fn setScrollRestoration(self: *History, str: []const u8) void {
    if (std.meta.stringToEnum(ScrollRestoration, str)) |sr| {
        self._scroll_restoration = sr;
    }
}

pub fn pushState(_: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, page: *Page) !void {
    const arena = page._session.arena;
    const url = if (_url) |u| try arena.dupeZ(u8, u) else try arena.dupeZ(u8, page.url);

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try page._session.navigation.pushEntry(url, .{ .source = .history, .value = json }, page, true);
}

pub fn replaceState(_: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, page: *Page) !void {
    const arena = page._session.arena;
    const url = if (_url) |u| try arena.dupeZ(u8, u) else try arena.dupeZ(u8, page.url);

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try page._session.navigation.replaceEntry(url, .{ .source = .history, .value = json }, page, true);
}

fn goInner(delta: i32, page: *Page) !void {
    // 0 behaves the same as no argument, both reloading the page.

    const current = page._session.navigation._index;
    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s > page._session.navigation._entries.items.len - 1) {
        return;
    }

    const index = @as(usize, @intCast(index_s));
    const entry = page._session.navigation._entries.items[index];

    if (entry._url) |url| {
        if (try page.isSameOrigin(url)) {
            const event = try PopStateEvent.initTrusted("popstate", .{ .state = entry._state.value }, page);

            const func = if (page.window._on_popstate) |*g| g.local() else null;
            try page._event_manager.dispatchWithFunction(
                page.window.asEventTarget(),
                event.asEvent(),
                func,
                .{ .context = "Pop State" },
            );
        }
    }

    _ = try page._session.navigation.navigateInner(entry._url, .{ .traverse = index }, page);
}

pub fn back(_: *History, page: *Page) !void {
    try goInner(-1, page);
}

pub fn forward(_: *History, page: *Page) !void {
    try goInner(1, page);
}

pub fn go(_: *History, delta: ?i32, page: *Page) !void {
    try goInner(delta orelse 0, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(History);

    pub const Meta = struct {
        pub const name = "History";
        pub var class_id: bridge.ClassId = 0;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const length = bridge.accessor(History.getLength, null, .{});
    pub const scrollRestoration = bridge.accessor(History.getScrollRestoration, History.setScrollRestoration, .{});
    pub const state = bridge.accessor(History.getState, null, .{});
    pub const pushState = bridge.function(History.pushState, .{});
    pub const replaceState = bridge.function(History.replaceState, .{});
    pub const back = bridge.function(History.back, .{});
    pub const forward = bridge.function(History.forward, .{});
    pub const go = bridge.function(History.go, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: History" {
    try testing.htmlRunner("history.html", .{});
}

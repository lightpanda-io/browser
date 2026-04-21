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

const Frame = @import("../Frame.zig");
const Location = @import("Location.zig");
const PopStateEvent = @import("event/PopStateEvent.zig");
const URL = @import("URL.zig");

const History = @This();

const ScrollRestoration = enum { auto, manual };

_scroll_restoration: ScrollRestoration = .auto,

pub fn getLength(_: *const History, frame: *Frame) u32 {
    return @intCast(frame._session.navigation._entries.items.len);
}

pub fn getState(_: *const History, frame: *Frame) !?js.Value {
    if (frame._session.navigation.getCurrentEntry()._state.value) |state| {
        const value = try frame.js.local.?.parseJSON(state);
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

pub fn pushState(_: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, frame: *Frame) !void {
    const arena = frame._session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena, frame.url, u, .{ .always_dupe = true })
    else
        try arena.dupeZ(u8, frame.url);

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try frame._session.navigation.pushEntry(url, .{ .source = .history, .value = json }, frame, true);

    frame.url = url;
    frame.window._location._url = try URL.init(url, null, &frame.js.execution);
}

pub fn replaceState(_: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, frame: *Frame) !void {
    const arena = frame._session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena, frame.url, u, .{ .always_dupe = true })
    else
        try arena.dupeZ(u8, frame.url);

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try frame._session.navigation.replaceEntry(url, .{ .source = .history, .value = json }, frame, true);

    frame.url = url;
    frame.window._location = try Location.init(url, frame);
}

fn goInner(delta: i32, frame: *Frame) !void {
    // 0 behaves the same as no argument, both reloading the frame.

    const current = frame._session.navigation._index;
    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s > frame._session.navigation._entries.items.len - 1) {
        return;
    }

    const index = @as(usize, @intCast(index_s));
    const entry = frame._session.navigation._entries.items[index];

    if (entry._url) |url| {
        if (frame.isSameOrigin(url)) {
            const target = frame.window.asEventTarget();
            if (frame._event_manager.hasDirectListeners(target, "popstate", frame.window._on_popstate)) {
                const event = (try PopStateEvent.initTrusted(comptime .wrap("popstate"), .{ .state = entry._state.value }, frame)).asEvent();
                try frame._event_manager.dispatchDirect(target, event, frame.window._on_popstate, .{ .context = "Pop State" });
            }
        }
    }

    _ = try frame._session.navigation.navigateInner(entry._url, .{ .traverse = index }, frame);
}

pub fn back(_: *History, frame: *Frame) !void {
    try goInner(-1, frame);
}

pub fn forward(_: *History, frame: *Frame) !void {
    try goInner(1, frame);
}

pub fn go(_: *History, delta: ?i32, frame: *Frame) !void {
    try goInner(delta orelse 0, frame);
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
    try testing.htmlRunner("history_url_update.html", .{});
}

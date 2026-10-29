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

const PopStateEvent = @import("event/PopStateEvent.zig");

const History = @This();

const ScrollRestoration = enum { auto, manual };

_frame: *Frame,
_scroll_restoration: ScrollRestoration = .auto,

pub fn getLength(self: *const History) u32 {
    const target = self._frame;
    return @intCast(target._session.navigationFor(target)._entries.items.len);
}

pub fn getState(self: *const History, frame: *Frame) !?js.Value {
    const target = self._frame;
    if (target._session.navigationFor(target).getCurrentEntry()._state.value) |state| {
        const value = try frame.js.local.?.parseJSON(state);
        return value;
    } else return null;
}

fn getScrollRestoration(self: *History) []const u8 {
    return @tagName(self._scroll_restoration);
}

fn setScrollRestoration(self: *History, str: []const u8) void {
    if (std.meta.stringToEnum(ScrollRestoration, str)) |sr| {
        self._scroll_restoration = sr;
    }
}

pub fn pushState(self: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8) !void {
    // The URL resolves against this history's document, not the caller's.
    const target = self._frame;
    const session = target._session;
    const arena = session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena.allocator(), target.url, u, .{})
    else
        try arena.dupeSentinel(u8, target.url, 0);

    const json = state.toJson(arena.allocator()) catch return error.DataClone;

    const navigation = session.navigationFor(target);
    const result = try navigation.fireNavigateEvent(.{ .navigation_type = .push, .url = url, .same_document = true, .classic_history = true }, target);
    if (result == .canceled) {
        return;
    }

    _ = try navigation.pushEntry(url, .{ .source = .history, .value = json }, target, true);

    target.url = url;
    // setHref == reinitializing.
    try target.window._location._url.setHref(url, &target.js.execution);
    // `:target` matches off the fragment, which the new URL can change.
    target.styleChanged();

    session.notification.dispatch(.frame_navigated_within_document, &.{
        .url = url,
        .frame_id = target._frame_id,
        .navigation_type = .historyApi,
    });

    if (result == .fired) {
        try navigation.commitSameDocument(result.fired, target);
    }
}

fn replaceState(self: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8) !void {
    // The URL resolves against this history's document, not the caller's.
    const target = self._frame;
    const session = target._session;
    const arena = session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena.allocator(), target.url, u, .{})
    else
        try arena.dupeSentinel(u8, target.url, 0);

    const json = state.toJson(arena.allocator()) catch return error.DataClone;

    const navigation = session.navigationFor(target);
    const result = try navigation.fireNavigateEvent(.{ .navigation_type = .replace, .url = url, .same_document = true, .classic_history = true }, target);
    if (result == .canceled) {
        return;
    }

    _ = try navigation.replaceEntry(url, .{ .source = .history, .value = json }, target, true);

    target.url = url;
    // setHref == reinitializing.
    try target.window._location._url.setHref(url, &target.js.execution);
    // `:target` matches off the fragment, which the new URL can change.
    target.styleChanged();

    session.notification.dispatch(.frame_navigated_within_document, &.{
        .url = url,
        .frame_id = target._frame_id,
        .navigation_type = .historyApi,
    });

    if (result == .fired) {
        try navigation.commitSameDocument(result.fired, target);
    }
}

fn goInner(delta: i32, frame: *Frame) !void {
    // 0 behaves the same as no argument, both reloading the frame.

    const navigation = frame._session.navigationFor(frame);
    const current = navigation._index;
    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s > navigation._entries.items.len - 1) {
        return;
    }

    try traverse(@intCast(index_s), frame);
}

// Traverses the session history to the entry at `index`. An entry of this
// document is restored in place, firing popstate; any other loads its
// document. Needs an entered JS context (navigateInner creates promises).
pub fn traverse(index: usize, frame: *Frame) !void {
    const navigation = frame._session.navigationFor(frame);
    const entry = navigation._entries.items[index];
    // popstate fires on the document that stays; a traversal to another
    // document replaces this one instead.
    const same_document = entry.sameDocument(frame);

    _ = try navigation.navigateInner(entry._url, .{ .traverse = index }, .{ .api_method = false }, frame);

    // The index doesn't move when the navigate event was canceled.
    if (same_document and navigation._index == index) {
        try firePopState(frame, entry._state.value);
        // hashchange is queued by navigateInner.
    }
}

// Fires popstate at the frame's window, synchronously: a same-document
// traversal or a fragment navigation updating the document for its new
// history entry. `state` is the entry's serialized state.
pub fn firePopState(frame: *Frame, state: ?[]const u8) !void {
    const target = frame.window.asEventTarget();
    if (frame._event_manager.hasDirectListeners(target, "popstate")) {
        const event = (try PopStateEvent.initTrusted(comptime .wrap("popstate"), .{ .state = state }, frame)).asEvent();
        try frame._event_manager.dispatchDirect(target, event, .{ .context = "Pop State" });
    }
}

// Traversals still act on the injected frame, not self._frame.
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
    try testing.htmlRunner("history_traverse.html", .{});
}

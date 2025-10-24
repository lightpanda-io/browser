// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const log = @import("../../log.zig");

const js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;
const Window = @import("window.zig").Window;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-history-interface
const History = @This();

const ScrollRestorationMode = enum {
    pub const ENUM_JS_USE_TAG = true;

    auto,
    manual,
};

scroll_restoration: ScrollRestorationMode = .auto,

pub fn get_length(_: *History, page: *Page) u32 {
    return @intCast(page.session.navigation.entries.items.len);
}

pub fn get_scrollRestoration(self: *History) ScrollRestorationMode {
    return self.scroll_restoration;
}

pub fn set_scrollRestoration(self: *History, mode: ScrollRestorationMode) void {
    self.scroll_restoration = mode;
}

pub fn get_state(_: *History, page: *Page) !?js.Value {
    if (page.session.navigation.currentEntry().state) |state| {
        const value = try js.Value.fromJson(page.js, state);
        return value;
    } else {
        return null;
    }
}

pub fn _pushState(_: *const History, state: js.Object, _: ?[]const u8, _url: ?[]const u8, page: *Page) !void {
    const arena = page.session.arena;
    const url = if (_url) |u| try arena.dupe(u8, u) else try arena.dupe(u8, page.url.raw);

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try page.session.navigation.pushEntry(url, json, page, true);
}

pub fn _replaceState(_: *const History, state: js.Object, _: ?[]const u8, _url: ?[]const u8, page: *Page) !void {
    const arena = page.session.arena;

    const entry = page.session.navigation.currentEntry();
    const json = try state.toJson(arena);
    const url = if (_url) |u| try arena.dupe(u8, u) else try arena.dupe(u8, page.url.raw);

    entry.state = json;
    entry.url = url;
}

pub fn go(_: *const History, delta: i32, page: *Page) !void {
    // 0 behaves the same as no argument, both reloading the page.

    const current = page.session.navigation.index;
    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s > page.session.navigation.entries.items.len - 1) {
        return;
    }

    const index = @as(usize, @intCast(index_s));
    const entry = page.session.navigation.entries.items[index];

    if (entry.url) |url| {
        if (try page.isSameOrigin(url)) {
            PopStateEvent.dispatch(entry.state, page);
        }
    }

    _ = try page.session.navigation.navigate(entry.url, .{ .traverse = index }, page);
}

pub fn _go(self: *History, _delta: ?i32, page: *Page) !void {
    try self.go(_delta orelse 0, page);
}

pub fn _back(self: *History, page: *Page) !void {
    try self.go(-1, page);
}

pub fn _forward(self: *History, page: *Page) !void {
    try self.go(1, page);
}

const parser = @import("../netsurf.zig");
const Event = @import("../events/event.zig").Event;

pub const PopStateEvent = struct {
    pub const prototype = *Event;
    pub const union_make_copy = true;

    pub const EventInit = struct {
        state: ?[]const u8 = null,
    };

    proto: parser.Event,
    state: ?[]const u8,

    pub fn constructor(event_type: []const u8, opts: ?EventInit) !PopStateEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{});
        parser.eventSetInternalType(event, .pop_state);

        const o = opts orelse EventInit{};

        return .{
            .proto = event.*,
            .state = o.state,
        };
    }

    // `hasUAVisualTransition` is not implemented. It isn't baseline so this is okay.

    pub fn get_state(self: *const PopStateEvent, page: *Page) !?js.Value {
        if (self.state) |state| {
            const value = try js.Value.fromJson(page.js, state);
            return value;
        } else {
            return null;
        }
    }

    pub fn dispatch(state: ?[]const u8, page: *Page) void {
        log.debug(.script_event, "dispatch popstate event", .{
            .type = "popstate",
            .source = "history",
        });

        var evt = PopStateEvent.constructor("popstate", .{ .state = state }) catch |err| {
            log.err(.app, "event constructor error", .{
                .err = err,
                .type = "popstate",
                .source = "history",
            });

            return;
        };

        _ = parser.eventTargetDispatchEvent(
            parser.toEventTarget(Window, &page.window),
            &evt.proto,
        ) catch |err| {
            log.err(.app, "dispatch popstate event error", .{
                .err = err,
                .type = "popstate",
                .source = "history",
            });
        };
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.History" {
    try testing.htmlRunner("html/history/history.html");
    try testing.htmlRunner("html/history/history2.html");
}

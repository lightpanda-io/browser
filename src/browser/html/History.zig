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

const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-history-interface
const History = @This();

const HistoryEntry = struct {
    url: []const u8,
    // Serialized as JSON.
    state: ?[]u8,
};

const ScrollRestorationMode = enum {
    auto,
    manual,

    pub fn fromString(str: []const u8) ?ScrollRestorationMode {
        for (std.enums.values(ScrollRestorationMode)) |mode| {
            if (std.ascii.eqlIgnoreCase(str, @tagName(mode))) {
                return mode;
            }
        } else {
            return null;
        }
    }
};

scrollRestoration: ScrollRestorationMode = .auto,
stack: std.ArrayListUnmanaged(HistoryEntry) = .empty,
current: ?usize = null,

pub fn get_length(self: *History) u32 {
    return @intCast(self.stack.items.len);
}

pub fn get_scrollRestoration(self: *History) []const u8 {
    return switch (self.scrollRestoration) {
        .auto => "auto",
        .manual => "manual",
    };
}

pub fn set_scrollRestoration(self: *History, mode: []const u8) void {
    self.scrollRestoration = ScrollRestorationMode.fromString(mode) orelse self.scrollRestoration;
}

pub fn get_state(self: *History, page: *Page) !?Env.Value {
    if (self.current) |curr| {
        const entry = self.stack.items[curr];
        if (entry.state) |state| {
            const value = try Env.Value.fromJson(page.main_context, state);
            return value;
        } else {
            return null;
        }
    } else {
        return null;
    }
}

pub fn pushNavigation(self: *History, _url: []const u8, page: *Page) !void {
    const arena = page.session.arena;
    const url = try arena.dupe(u8, _url);

    const entry = HistoryEntry{ .state = null, .url = url };
    try self.stack.append(arena, entry);
    self.current = self.stack.items.len - 1;
}

pub fn dispatchPopStateEvent(state: ?[]const u8, page: *Page) void {
    log.debug(.script_event, "dispatch popstate event", .{
        .type = "popstate",
        .source = "history",
    });
    History._dispatchPopStateEvent(state, page) catch |err| {
        log.err(.app, "dispatch popstate event error", .{
            .err = err,
            .type = "popstate",
            .source = "history",
        });
    };
}

fn _dispatchPopStateEvent(
    state: ?[]const u8,
    page: *Page,
) !void {
    var evt = try PopStateEvent.constructor("popstate", .{ .state = state });

    _ = try parser.eventTargetDispatchEvent(
        @as(*parser.EventTarget, @ptrCast(&page.window)),
        @as(*parser.Event, @ptrCast(&evt)),
    );
}

pub fn _pushState(self: *History, state: Env.JsObject, _: ?[]const u8, _url: ?[]const u8, page: *Page) !void {
    const arena = page.session.arena;

    const url = if (_url) |u| try arena.dupe(u8, u) else try arena.dupe(u8, page.url.raw);
    const json = try state.toJson(page.session.arena);
    const entry = HistoryEntry{ .state = json, .url = url };
    try self.stack.append(arena, entry);
    self.current = self.stack.items.len - 1;
}

pub fn _replaceState(self: *History, state: Env.JsObject, _: ?[]const u8, _url: ?[]const u8, page: *Page) !void {
    const arena = page.session.arena;

    if (self.current) |curr| {
        const entry = &self.stack.items[curr];
        const url = if (_url) |u| try arena.dupe(u8, u) else try arena.dupe(u8, page.url.raw);
        const json = try state.toJson(arena);
        entry.* = HistoryEntry{ .state = json, .url = url };
    } else {
        try self._pushState(state, "", _url, page);
    }
}

pub fn go(self: *History, delta: i32, page: *Page) !void {
    // 0 behaves the same as no argument, both reloading the page.
    // If this is getting called, there SHOULD be an entry, atleast from pushNavigation.
    const current = self.current.?;

    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s > self.stack.items.len - 1) {
        return;
    }

    const index = @as(usize, @intCast(index_s));
    const entry = self.stack.items[index];
    self.current = index;

    if (try page.isSameOrigin(entry.url)) {
        if (entry.state) |state| {
            History.dispatchPopStateEvent(state, page);
        } else {
            History.dispatchPopStateEvent(null, page);
        }
    }

    try page.navigateFromWebAPI(entry.url, .{ .reason = .history });
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

    pub fn get_state(self: *const PopStateEvent, page: *Page) !?Env.Value {
        if (self.state) |state| {
            const value = try Env.Value.fromJson(page.main_context, state);
            return value;
        } else {
            return null;
        }
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.History" {
    try testing.htmlRunner("html/history.html");
}

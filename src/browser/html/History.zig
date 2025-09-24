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

const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-history-interface
const History = @This();

const HistoryEntry = struct {
    url: ?[]const u8,
    // Serialized Env.JsObject
    state: []u8,
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

pub fn get_state(self: *History, page: *Page) !?Env.JsObject {
    if (self.current) |curr| {
        const entry = self.stack.items[curr];
        const object = try Env.JsObject.fromJson(page.main_context, entry.state);
        return object;
    } else {
        return null;
    }
}

pub fn _pushState(self: *History, state: Env.JsObject, _: ?[]const u8, url: ?[]const u8, page: *Page) !void {
    const json = try state.toJson(page.arena);
    const entry = HistoryEntry{ .state = json, .url = url };
    try self.stack.append(page.session.arena, entry);
    self.current = self.stack.items.len;
}

// TODO implement the function
// data must handle any argument. We could expect a std.json.Value but
// https://github.com/lightpanda-io/zig-js-runtime/issues/267 is missing.
pub fn _replaceState(self: *History, state: Env.JsObject, _: ?[]const u8, url: ?[]const u8) void {
    _ = self;
    _ = url;
    _ = state;
}

// TODO implement the function
pub fn _go(self: *History, delta: ?i32) void {
    _ = self;
    _ = delta;
}

pub fn _back(self: *History) void {
    if (self.current) |curr| {
        if (curr > 0) {
            self.current = curr - 1;
        }
    }
}

pub fn _forward(self: *History) void {
    if (self.current) |curr| {
        if (curr < self.stack.items.len) {
            self.current = curr + 1;
        }
    }
}

const testing = @import("../../testing.zig");
test "Browser: HTML.History" {
    try testing.htmlRunner("html/history.html");
}

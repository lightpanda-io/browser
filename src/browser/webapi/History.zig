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

const History = @This();

_page: *Page,
_length: u32 = 1,
_state: ?js.Object = null,

pub fn init(page: *Page) History {
    return .{
        ._page = page,
    };
}

pub fn deinit(self: *History) void {
    if (self._state) |state| {
        js.q.JS_FreeValue(self._page.js.ctx, state.value);
    }
}

pub fn getLength(self: *const History) u32 {
    return self._length;
}

pub fn getState(self: *const History) ?js.Object {
    return self._state;
}

pub fn pushState(self: *History, state: js.Object, _title: []const u8, url: ?[]const u8, page: *Page) !void {
    _ = _title; // title is ignored in modern browsers
    _ = url; // For minimal implementation, we don't actually navigate
    _ = page;

    self._state = state;
    self._length += 1;
}

pub fn replaceState(self: *History, state: js.Object, _title: []const u8, url: ?[]const u8, page: *Page) !void {
    _ = _title;
    _ = url;
    _ = page;
    self._state = state;
    // Note: replaceState doesn't change length
}

pub fn back(self: *History, page: *Page) void {
    _ = self;
    _ = page;
    // Minimal implementation: no-op
}

pub fn forward(self: *History, page: *Page) void {
    _ = self;
    _ = page;
    // Minimal implementation: no-op
}

pub fn go(self: *History, delta: i32, page: *Page) void {
    _ = self;
    _ = delta;
    _ = page;
    // Minimal implementation: no-op
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(History);

    pub const Meta = struct {
        pub const name = "History";
        pub var class_id: bridge.ClassId = 0;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const length = bridge.accessor(History.getLength, null, .{});
    pub const state = bridge.accessor(History.getState, null, .{});
    pub const pushState = bridge.function(History.pushState, .{});
    pub const replaceState = bridge.function(History.replaceState, .{});
    pub const back = bridge.function(History.back, .{});
    pub const forward = bridge.function(History.forward, .{});
    pub const go = bridge.function(History.go, .{});
};

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

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-history-interface
pub const History = struct {
    const ScrollRestorationMode = enum {
        auto,
        manual,
    };

    scrollRestoration: ScrollRestorationMode = .auto,
    state: std.json.Value = .null,

    // count tracks the history length until we implement correctly pushstate.
    count: u32 = 0,

    pub fn get_length(self: *History) u32 {
        // TODO return the real history length value.
        return self.count;
    }

    pub fn get_scrollRestoration(self: *History) []const u8 {
        return switch (self.scrollRestoration) {
            .auto => "auto",
            .manual => "manual",
        };
    }

    pub fn set_scrollRestoration(self: *History, mode: []const u8) void {
        if (std.mem.eql(u8, "manual", mode)) self.scrollRestoration = .manual;
        if (std.mem.eql(u8, "auto", mode)) self.scrollRestoration = .auto;
    }

    pub fn get_state(self: *History) std.json.Value {
        return self.state;
    }

    // TODO implement the function
    // data must handle any argument. We could expect a std.json.Value but
    // https://github.com/lightpanda-io/zig-js-runtime/issues/267 is missing.
    pub fn _pushState(self: *History, data: []const u8, _: ?[]const u8, url: ?[]const u8) void {
        self.count += 1;
        _ = url;
        _ = data;
    }

    // TODO implement the function
    // data must handle any argument. We could expect a std.json.Value but
    // https://github.com/lightpanda-io/zig-js-runtime/issues/267 is missing.
    pub fn _replaceState(self: *History, data: []const u8, _: ?[]const u8, url: ?[]const u8) void {
        _ = self;
        _ = url;
        _ = data;
    }

    // TODO implement the function
    pub fn _go(self: *History, delta: ?i32) void {
        _ = self;
        _ = delta;
    }

    // TODO implement the function
    pub fn _back(self: *History) void {
        _ = self;
    }

    // TODO implement the function
    pub fn _forward(self: *History) void {
        _ = self;
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.History" {
    try testing.htmlRunner("html/history.html");
}

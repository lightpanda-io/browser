// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! https://w3c.github.io/clipboard-apis/#clipboard-interface

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");

const Execution = js.Execution;

const Clipboard = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

/// Needs clipboard-read, which only CDP grants, as in Chrome: a page can't
/// read what the user copied unless it was allowed to.
fn readText(_: *const Clipboard, exec: *Execution) !js.Promise {
    const browser = exec.session.browser;
    if (browser.permissions.get("clipboard-read") orelse .prompt != .granted) {
        return error.NotAllowedError;
    }
    return exec.js.local.?.resolvePromise(browser.clipboard);
}

/// Chrome lets a page write after a click (transient activation) or with
/// clipboard-write. Lightpanda doesn't track activation, so writes always
/// succeed: copy buttons are what pages call this from.
fn writeText(_: *const Clipboard, data: []const u8, exec: *Execution) !js.Promise {
    const browser = exec.session.browser;
    if (browser.permissions.get("clipboard-write") orelse .prompt == .denied) {
        return error.NotAllowedError;
    }
    // A copy of exactly this size: a large write isn't kept past the next one
    const copy = try browser.allocator.dupe(u8, data);
    browser.allocator.free(browser.clipboard);
    browser.clipboard = copy;
    return exec.js.local.?.resolvePromise({});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Clipboard);

    pub const Meta = struct {
        pub const name = "Clipboard";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const readText = bridge.function(Clipboard.readText, .{});
    pub const writeText = bridge.function(Clipboard.writeText, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Clipboard" {
    try testing.htmlRunner("clipboard.html", .{});
}

test "WebApi: Clipboard granted" {
    const browser = testing.test_session.browser;
    defer {
        browser.clearPermissions();
        browser.allocator.free(browser.clipboard);
        browser.clipboard = "";
    }
    try browser.setPermission("clipboard-read", .granted);
    try testing.htmlRunner("clipboard_granted.html", .{});
}

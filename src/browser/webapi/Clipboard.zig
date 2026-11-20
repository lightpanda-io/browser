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

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");

const Execution = js.Execution;

/// https://w3c.github.io/clipboard-apis/#clipboard-interface
/// The text lives on the Browser (Browser.clipboard), never the system's.
const Clipboard = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

pub fn init(exec: *Execution) !*Clipboard {
    return exec._factory.eventTarget(Clipboard{ ._proto = undefined });
}

pub fn asEventTarget(self: *Clipboard) *EventTarget {
    return self._proto;
}

/// Needs clipboard-read, which only CDP grants, as in Chrome: a page can't
/// read what the user copied unless it was allowed to.
fn readText(_: *const Clipboard, exec: *Execution) !js.Promise {
    const browser = exec.session.browser;
    if (browser.getPermission("clipboard-read") != .granted) {
        return error.NotAllowedError;
    }
    return exec.js.local.?.resolvePromise(browser.clipboard.items);
}

/// Chrome lets a page write after a click (transient activation) or with
/// clipboard-write. Lightpanda doesn't track activation, so writes always
/// succeed: copy buttons are what pages call this from.
fn writeText(_: *const Clipboard, data: []const u8, exec: *Execution) !js.Promise {
    const browser = exec.session.browser;
    if (browser.getPermission("clipboard-write") == .denied) {
        return error.NotAllowedError;
    }
    browser.clipboard.clearRetainingCapacity();
    try browser.clipboard.appendSlice(browser.allocator, data);
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
        browser.clipboard.clearRetainingCapacity();
    }
    // What Playwright sends for permissions: ['clipboard-read']
    try browser.setPermission("clipboardReadWrite", .granted);
    try testing.htmlRunner("clipboard_granted.html", .{});
}

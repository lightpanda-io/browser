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

const Viewport = @This();

width: u32,
height: u32,

pub const default = Viewport{
    .width = 1920,
    .height = 1080,
};

// The viewport is the *content* area (window.innerWidth/innerHeight). Real
// browsers stack more chrome on top of it, and bot scanners check that the
// chain screen >= avail >= outer > inner holds — equality anywhere in the
// height chain only happens headless.
//
//   screen.height  = inner + browser chrome + OS chrome
//   availHeight    = outerHeight            (window is maximized)
//   outerHeight    = inner + browser chrome (tab strip + omnibox)
//
// 80 + 40 on the 1080 default lands on 1200, a real desktop resolution.
const browser_chrome_height = 80;
const os_chrome_height = 40;

/// Outer window height: content plus the tab strip and omnibox.
pub fn outerHeight(self: Viewport) u32 {
    return self.height + browser_chrome_height;
}

/// Screen height: the outer window plus the taskbar/dock it can't cover.
pub fn screenHeight(self: Viewport) u32 {
    return self.outerHeight() + os_chrome_height;
}

/// Inverse of `screenHeight`: the content viewport a maximized window gets on a
/// screen of this size. Used to turn a fingerprint profile's resolution into a
/// viewport that reports that exact resolution back through `screen`.
pub fn fromScreen(width: u32, height: u32) Viewport {
    return .{
        .width = width,
        .height = height -| (browser_chrome_height + os_chrome_height),
    };
}

const testing = @import("../testing.zig");

test "Viewport: geometry chain is browser-plausible" {
    for ([_]Viewport{ default, fromScreen(1366, 768), fromScreen(3840, 2160) }) |v| {
        try testing.expect(v.screenHeight() >= v.outerHeight());
        try testing.expect(v.outerHeight() > v.height);
    }
    // A fingerprint profile's resolution round-trips through `screen`.
    try testing.expectEqual(1080, fromScreen(1920, 1080).screenHeight());
}

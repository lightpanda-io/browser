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

const builtin = @import("builtin");
const js = @import("../js/js.zig");

const Navigator = @This();
_pad: bool = false,

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator) []const u8 {
    return "Mozilla/5.0 (compatible; LiteFetch/0.1)";
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return "LiteFetch";
}

pub fn getAppVersion(_: *const Navigator) []const u8 {
    return "0.1";
}

pub fn getPlatform(_: *const Navigator) []const u8 {
    return switch (builtin.os.tag) {
        .macos => "MacIntel",
        .windows => "Win32",
        .linux => "Linux x86_64",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

pub fn getLanguage(_: *const Navigator) []const u8 {
    return "en-US";
}

pub fn getLanguages(_: *const Navigator) [1][]const u8 {
    return .{"en-US"};
}

pub fn getOnLine(_: *const Navigator) bool {
    return true;
}

pub fn getCookieEnabled(_: *const Navigator) bool {
    // TODO: Implement cookie support
    return false;
}

pub fn getHardwareConcurrency(_: *const Navigator) u32 {
    return 4;
}

pub fn getMaxTouchPoints(_: *const Navigator) u32 {
    return 0;
}

/// Returns the vendor name
pub fn getVendor(_: *const Navigator) []const u8 {
    return "LiteFetch";
}

/// Returns the product name (typically "Gecko" for compatibility)
pub fn getProduct(_: *const Navigator) []const u8 {
    return "Gecko";
}

/// Returns whether Java is enabled (always false)
pub fn javaEnabled(_: *const Navigator) bool {
    return false;
}

/// Returns whether the browser is controlled by automation (always false)
pub fn getWebdriver(_: *const Navigator) bool {
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigator);

    pub const Meta = struct {
        pub const name = "Navigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // ZIGDOM (currently no optimization for empty types)
        pub const empty_with_no_proto = true;
    };

    // Read-only properties
    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const language = bridge.accessor(Navigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(Navigator.getOnLine, null, .{});
    pub const cookieEnabled = bridge.accessor(Navigator.getCookieEnabled, null, .{});
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{});
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{});

    // Methods
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
};

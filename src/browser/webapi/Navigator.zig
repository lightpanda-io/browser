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
const builtin = @import("builtin");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Navigator = @This();
_pad: bool = false,

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, page: *Page) []const u8 {
    return page._session.browser.app.config.user_agent;
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return "Netscape";
}

pub fn getAppCodeName(_: *const Navigator) []const u8 {
    return "Netscape";
}

pub fn getAppVersion(_: *const Navigator) []const u8 {
    return "1.0";
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
    return true;
}

pub fn getHardwareConcurrency(_: *const Navigator) u32 {
    return 4;
}

pub fn getMaxTouchPoints(_: *const Navigator) u32 {
    return 0;
}

/// Returns the vendor name
pub fn getVendor(_: *const Navigator) []const u8 {
    return "";
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

pub fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, page: *const Page) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, page);
}
pub fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, page: *const Page) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, page);
}

fn validateProtocolHandlerScheme(scheme: []const u8) !void {
    const allowed = std.StaticStringMap(void).initComptime(.{
        .{ "bitcoin", {} },
        .{ "cabal", {} },
        .{ "dat", {} },
        .{ "did", {} },
        .{ "dweb", {} },
        .{ "ethereum", .{} },
        .{ "ftp", {} },
        .{ "ftps", {} },
        .{ "geo", {} },
        .{ "im", {} },
        .{ "ipfs", {} },
        .{ "ipns", .{} },
        .{ "irc", {} },
        .{ "ircs", {} },
        .{ "hyper", {} },
        .{ "magnet", {} },
        .{ "mailto", {} },
        .{ "matrix", {} },
        .{ "mms", {} },
        .{ "news", {} },
        .{ "nntp", {} },
        .{ "openpgp4fpr", {} },
        .{ "sftp", {} },
        .{ "sip", {} },
        .{ "sms", {} },
        .{ "smsto", {} },
        .{ "ssb", {} },
        .{ "ssh", {} },
        .{ "tel", {} },
        .{ "urn", {} },
        .{ "webcal", {} },
        .{ "wtai", {} },
        .{ "xmpp", {} },
    });
    if (allowed.has(scheme)) {
        return;
    }

    if (scheme.len < 5 or !std.mem.startsWith(u8, scheme, "web+")) {
        return error.SecurityError;
    }
    for (scheme[4..]) |b| {
        if (std.ascii.isLower(b) == false) {
            return error.SecurityError;
        }
    }
}

fn validateProtocolHandlerURL(url: [:0]const u8, page: *const Page) !void {
    if (std.mem.indexOf(u8, url, "%s") == null) {
        return error.SyntaxError;
    }
    if (try page.isSameOrigin(url) == false) {
        return error.SyntaxError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigator);

    pub const Meta = struct {
        pub const name = "Navigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    // Read-only properties
    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appCodeName = bridge.accessor(Navigator.getAppCodeName, null, .{});
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
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .dom_exception = true });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .dom_exception = true });

    // Methods
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
};

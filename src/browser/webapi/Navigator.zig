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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const PluginArray = @import("PluginArray.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");

const log = lp.log;

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_permissions: Permissions = .{},
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, frame: *Frame) []const u8 {
    return frame._session.browser.http_client.getUserAgent();
}

pub fn getLanguages(_: *const Navigator) [2][]const u8 {
    return .{ "en-US", "en" };
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

/// Returns whether Java is enabled (always false)
pub fn javaEnabled(_: *const Navigator) bool {
    return false;
}

pub fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

pub fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

pub fn getStorage(self: *Navigator) *StorageManager {
    return &self._storage;
}

pub fn getUserAgentData(self: *Navigator) *NavigatorUAData {
    return &self._ua_data;
}

pub fn getBattery(_: *const Navigator, frame: *Frame) !js.Promise {
    log.info(.not_implemented, "navigator.getBattery", .{});
    return frame.js.local.?.rejectErrorPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
}

pub fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}
pub fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
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

fn validateProtocolHandlerURL(url: [:0]const u8, frame: *const Frame) !void {
    if (std.mem.indexOf(u8, url, "%s") == null) {
        return error.SyntaxError;
    }
    if (frame.isSameOrigin(url) == false) {
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
    pub const appName = bridge.property("Netscape", .{ .template = false });
    pub const appCodeName = bridge.property("Netscape", .{ .template = false });
    pub const appVersion = bridge.property("1.0", .{ .template = false });
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const language = bridge.property("en-US", .{ .template = false });
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.property(true, .{ .template = false });
    pub const cookieEnabled = bridge.property(true, .{ .template = false });
    pub const hardwareConcurrency = bridge.property(4, .{ .template = false });
    pub const deviceMemory = bridge.property(@as(f64, 8.0), .{ .template = false });
    pub const maxTouchPoints = bridge.property(0, .{ .template = false });
    pub const vendor = bridge.property("", .{ .template = false });
    pub const product = bridge.property("Gecko", .{ .template = false });
    pub const webdriver = bridge.property(false, .{ .template = false });
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{});
    pub const doNotTrack = bridge.property(null, .{ .template = false });
    pub const globalPrivacyControl = bridge.property(true, .{ .template = false });
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .dom_exception = true });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .dom_exception = true });

    // Methods
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const getBattery = bridge.function(Navigator.getBattery, .{});
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Navigator" {
    try testing.htmlRunner("navigator", .{});
}

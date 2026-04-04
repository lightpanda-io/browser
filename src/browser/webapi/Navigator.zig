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
const URL = @import("../URL.zig");
const DOMException = @import("DOMException.zig");
const PluginArray = @import("PluginArray.zig");
const MimeTypeArray = @import("MimeTypeArray.zig");

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_mime_types: MimeTypeArray = .{},
_user_agent_data: UserAgentData = .{},
_webkit_temporary_storage: StorageQuota = .{ ._request_error_name = "AbortError" },
_webkit_persistent_storage: StorageQuota = .{ ._request_error_name = "AbortError" },

pub const init: Navigator = .{};

pub fn registerTypes() []const type {
    return &.{
        Navigator,
        UserAgentData,
        Brand,
        StorageQuota,
    };
}

const Brand = struct {
    _brand: []const u8 = "",
    _version: []const u8 = "",

    pub fn getBrand(self: *const Brand) []const u8 {
        return self._brand;
    }

    pub fn getVersion(self: *const Brand) []const u8 {
        return self._version;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Brand);

        pub const Meta = struct {
            pub const name = "NavigatorUADataBrandVersion";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const brand = bridge.accessor(Brand.getBrand, null, .{});
        pub const version = bridge.accessor(Brand.getVersion, null, .{});
    };
};

const UserAgentData = struct {
    _brands: [2]Brand = .{
        .{ ._brand = "Lightpanda", ._version = "1" },
        .{ ._brand = "Not.A/Brand", ._version = "99" },
    },

    const BrandSnapshot = struct {
        brand: []const u8,
        version: []const u8,
    };

    const HighEntropyValues = struct {
        brands: [2]BrandSnapshot,
        mobile: bool,
        architecture: []const u8,
        bitness: []const u8,
        model: []const u8,
        platform: []const u8,
        platformVersion: []const u8,
        uaFullVersion: []const u8,
        wow64: bool,
    };

    const Snapshot = struct {
        brands: []const Brand,
        mobile: bool,
        platform: []const u8,
    };

    pub fn getBrands(self: *const UserAgentData) []const Brand {
        return self._brands[0..];
    }

    pub fn getPlatform(_: *const UserAgentData) []const u8 {
        return uachPlatformName();
    }

    pub fn getHighEntropyValues(self: *const UserAgentData, hints: []const []const u8, page: *Page) !js.Promise {
        _ = hints;
        return page.js.local.?.resolvePromise(HighEntropyValues{
            .brands = .{
                .{ .brand = self._brands[0]._brand, .version = self._brands[0]._version },
                .{ .brand = self._brands[1]._brand, .version = self._brands[1]._version },
            },
            .mobile = false,
            .architecture = uachArchitecture(),
            .bitness = uachBitness(),
            .model = "",
            .platform = uachPlatformName(),
            .platformVersion = uachPlatformVersion(),
            .uaFullVersion = "1.0.0",
            .wow64 = false,
        });
    }

    pub fn toJSON(self: *const UserAgentData) Snapshot {
        return .{
            .brands = self.getBrands(),
            .mobile = false,
            .platform = self.getPlatform(),
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(UserAgentData);

        pub const Meta = struct {
            pub const name = "NavigatorUAData";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const brands = bridge.accessor(UserAgentData.getBrands, null, .{});
        pub const mobile = bridge.property(false, .{ .template = false });
        pub const platform = bridge.accessor(UserAgentData.getPlatform, null, .{});
        pub const getHighEntropyValues = bridge.function(UserAgentData.getHighEntropyValues, .{});
        pub const toJSON = bridge.function(UserAgentData.toJSON, .{});
    };
};

const StorageQuota = struct {
    _request_error_name: []const u8 = "AbortError",

    pub fn queryUsageAndQuota(_: *const StorageQuota, _: js.Function.Temp, error_callback: ?js.Function.Temp, page: *Page) !void {
        if (error_callback) |cb| {
            try cb.local(page.js.local.?).call(void, .{DOMException.init(null, "NotSupportedError")});
        }
    }

    pub fn requestQuota(self: *const StorageQuota, _: u64, _: js.Function.Temp, error_callback: ?js.Function.Temp, page: *Page) !void {
        if (error_callback) |cb| {
            try cb.local(page.js.local.?).call(void, .{DOMException.init(null, self._request_error_name)});
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageQuota);

        pub const Meta = struct {
            pub const name = "StorageQuota";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const queryUsageAndQuota = bridge.function(StorageQuota.queryUsageAndQuota, .{});
        pub const requestQuota = bridge.function(StorageQuota.requestQuota, .{});
    };
};

pub fn getUserAgent(_: *const Navigator, page: *Page) []const u8 {
    return page._session.browser.app.config.http_headers.user_agent;
}

pub fn getLanguages(_: *const Navigator) [1][]const u8 {
    return .{"en-GB"};
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

pub fn getHardwareConcurrency(_: *const Navigator) u32 {
    const count = std.Thread.getCpuCount() catch 8;
    return @intCast(@max(count, 1));
}

/// Returns whether Java is enabled (always false)
pub fn javaEnabled(_: *const Navigator) bool {
    return false;
}

pub fn getGamepads(_: *const Navigator) [4]?u8 {
    return .{ null, null, null, null };
}

pub fn vibrate(_: *const Navigator, _: js.Value.Temp) bool {
    return true;
}

pub fn sendBeacon(_: *const Navigator, url: []const u8, _: ?js.Value.Temp, page: *Page) !bool {
    const resolved = try URL.resolve(page.call_arena, page.base(), url, .{ .always_dupe = true });
    const protocol = URL.getProtocol(resolved);
    if (!std.mem.eql(u8, protocol, "http:") and !std.mem.eql(u8, protocol, "https:")) {
        return error.TypeError;
    }
    return true;
}

pub fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

pub fn getMimeTypes(self: *Navigator) *MimeTypeArray {
    return &self._mime_types;
}

pub fn getUserAgentData(self: *Navigator) *UserAgentData {
    return &self._user_agent_data;
}

pub fn getWebkitTemporaryStorage(self: *Navigator) *StorageQuota {
    return &self._webkit_temporary_storage;
}

pub fn getWebkitPersistentStorage(self: *Navigator) *StorageQuota {
    return &self._webkit_persistent_storage;
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

fn uachPlatformName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macOS",
        .windows => "Windows",
        .linux => "Linux",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

fn uachPlatformVersion() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "10.0.0",
        .macos => "15.0.0",
        else => "0.0.0",
    };
}

fn uachArchitecture() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => "x86",
        .arm, .aarch64 => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}

fn uachBitness() []const u8 {
    return switch (@bitSizeOf(usize)) {
        64 => "64",
        32 => "32",
        else => "0",
    };
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
    pub const language = bridge.property("en-GB", .{ .template = false });
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.property(true, .{ .template = false });
    pub const cookieEnabled = bridge.property(true, .{ .template = false });
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const maxTouchPoints = bridge.property(2, .{ .template = false });
    pub const vendor = bridge.property("Google Inc.", .{ .template = false });
    pub const vendorSub = bridge.property("", .{ .template = false });
    pub const product = bridge.property("Gecko", .{ .template = false });
    pub const productSub = bridge.property("20030107", .{ .template = false });
    pub const webdriver = bridge.property(false, .{ .template = false });
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{});
    pub const mimeTypes = bridge.accessor(Navigator.getMimeTypes, null, .{});
    pub const pdfViewerEnabled = bridge.property(true, .{ .template = false });
    pub const webkitTemporaryStorage = bridge.accessor(Navigator.getWebkitTemporaryStorage, null, .{});
    pub const webkitPersistentStorage = bridge.accessor(Navigator.getWebkitPersistentStorage, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});
    pub const doNotTrack = bridge.property(null, .{ .template = false });
    pub const globalPrivacyControl = bridge.property(true, .{ .template = false });
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .dom_exception = true });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .dom_exception = true });

    // Methods
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const getGamepads = bridge.function(Navigator.getGamepads, .{});
    pub const vibrate = bridge.function(Navigator.vibrate, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{});
};

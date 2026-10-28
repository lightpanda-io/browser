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
const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const BodyInit = @import("net/body_init.zig").BodyInit;

const PluginArray = @import("PluginArray.zig");
const Permissions = @import("Permissions.zig");
const ModelContext = @import("ModelContext.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const Geolocation = @import("geolocation/Geolocation.zig");
const ServiceWorkerContainer = @import("ServiceWorkerContainer.zig");
const LockManager = @import("LockManager.zig");

const Execution = js.Execution;
const resource_load = Frame.resource_load;

const Navigator = @This();

comptime {
    // Ensure we don't cause an identity map conflict. Because _geolocation is
    // lazy and, for now, Zig orders the highest-aligned field first, none of
    // the other fields land at offset 0.
    for ([_][]const u8{ "_plugins", "_permissions", "_storage", "_ua_data" }) |name| {
        if (@offsetOf(Navigator, name) == 0) @compileError(name ++ " aliases the Navigator");
    }
}

_plugins: PluginArray = .{},
_permissions: Permissions = .{},
_geolocation: ?*Geolocation = null,
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},
_service_worker: ?*ServiceWorkerContainer = null,
_locks: ?*LockManager = null,
_beacon_bytes: ?*usize = null,

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, exec: *const Execution) []const u8 {
    return exec.session.browser.http_client.getUserAgent();
}

pub fn getLanguages(_: *const Navigator, exec: *const Execution) []const []const u8 {
    return exec.session.browser.http_client.getLanguages();
}

fn getDoNotTrack(_: *const Navigator) ?[]const u8 {
    return null;
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return "Netscape";
}

pub fn getAppCodeName(_: *const Navigator) []const u8 {
    return "Mozilla";
}

pub fn getAppVersion(_: *const Navigator) []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "5.0 (Macintosh)",
        .windows => "5.0 (Windows)",
        else => "5.0 (X11)",
    };
}

pub fn getLanguage(self: *const Navigator, exec: *const Execution) []const u8 {
    const languages = self.getLanguages(exec);
    return if (languages.len == 0) "" else languages[0];
}

pub fn getOnLine(_: *const Navigator) bool {
    return true;
}

fn getCookieEnabled(_: *const Navigator) bool {
    return true;
}

pub fn getHardwareConcurrency(_: *const Navigator) u32 {
    return 4;
}

pub fn getDeviceMemory(_: *const Navigator) f64 {
    return 8.0;
}

fn getMaxTouchPoints(_: *const Navigator) u32 {
    return 0;
}

pub fn getVendor(_: *const Navigator) []const u8 {
    return "";
}

pub fn getProduct(_: *const Navigator) []const u8 {
    return "Gecko";
}

fn getWebdriver(_: *const Navigator) bool {
    return false;
}

// Default to false: per https://w3c.github.io/gpc/#javascript-property the
// signal reflects an explicit user preference, and none is configured here.
// Firefox defaults to false; Chrome doesn't expose the property. Returning
// true made GPC-compliant consent managers treat every page load as "reject
// tracking" and skip their consent UI entirely.
pub fn getGlobalPrivacyControl(_: *const Navigator) bool {
    return false;
}

pub fn getPlatform(_: *const Navigator) []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "MacIntel",
        .windows => "Win32",
        .linux => "Linux x86_64",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

/// Returns whether Java is enabled (always false)
fn javaEnabled(_: *const Navigator) bool {
    return false;
}

/// The keepalive quota: a document's in-flight keepalive request bodies,
/// beacons here, can't add up to more than 64 KiB (Fetch, "HTTP-network-or-cache
/// fetch").
const keepalive_quota = 64 * 1024;

/// https://w3c.github.io/beacon/#sec-processing-model
/// Only sent if --load-resources beacon is set.
fn sendBeacon(self: *Navigator, url: []const u8, data: ?BodyInit, frame: *Frame) !bool {
    const resolved = URL.resolve(frame.local_arena, frame.base(), url, .{}) catch {
        return frame.js.typeError("sendBeacon: invalid URL");
    };
    if (URL.isRemoteScheme(resolved) == false) {
        return frame.js.typeError("sendBeacon: the URL's scheme must be http or https");
    }

    var body: []const u8 = "";
    var content_type: ?[]const u8 = null;
    if (data) |d| {
        if (d == .stream) {
            // A keepalive request can't have a ReadableStream body.
            return frame.js.typeError("sendBeacon: a ReadableStream body is not supported");
        }
        const extracted = try d.extract(frame.local_arena);
        body = extracted.bytes;
        content_type = extracted.content_type;
    }

    if (frame._session.load_resources.beacon == false) {
        // Nothing is ever in flight, so only this body counts against the quota.
        if (body.len > keepalive_quota) {
            return false;
        }
        frame.page.status.noteSkipped(.beacon);
        return true;
    }

    // keep the # of bytes in-flight for the keepalive quota
    const in_flight = self._beacon_bytes orelse blk: {
        // windows can be re-used, heap allocate this so that each document
        // gets its own counter, and old beacons decrement what they counted
        // against.
        const counter = try frame.page_arena.create(usize);
        counter.* = 0;
        self._beacon_bytes = counter;
        break :blk counter;
    };
    if (in_flight.* + body.len > keepalive_quota) {
        return false;
    }
    try resource_load.beacon(frame, in_flight, resolved, body, content_type);
    return true;
}

fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

fn getGeolocation(self: *Navigator, exec: *Execution) !*Geolocation {
    if (self._geolocation) |g| {
        return g;
    }
    const g = try exec._factory.create(Geolocation{});
    self._geolocation = g;
    return g;
}

fn getStorage(self: *Navigator) *StorageManager {
    return &self._storage;
}

// NOTE, the binding for this API is removed at runtime if ServiceWorkers are
// not enabled (Env.createContext; by default, they are not) or if the frame
// isn't a secure context (Context.setOrigin).
fn getServiceWorker(self: *Navigator, frame: *Frame) !*ServiceWorkerContainer {
    if (self._service_worker) |sw| {
        return sw;
    }
    const sw = try ServiceWorkerContainer.init(frame);
    self._service_worker = sw;
    return sw;
}

fn getLocks(self: *Navigator, exec: *Execution) !*LockManager {
    if (self._locks) |l| {
        return l;
    }
    const l = try exec._factory.create(LockManager{});
    self._locks = l;
    return l;
}

fn getUserAgentData(self: *Navigator) *NavigatorUAData {
    return &self._ua_data;
}

fn getModelContext(_: *const Navigator, frame: *Frame) *ModelContext {
    return &frame.window._model_context;
}

fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}
fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
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
    if (std.mem.find(u8, url, "%s") == null) {
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
        pub var class_id: bridge.ClassId = undefined;
    };

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
    pub const deviceMemory = bridge.accessor(Navigator.getDeviceMemory, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{});
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{});
    pub const doNotTrack = bridge.accessor(Navigator.getDoNotTrack, null, .{});
    pub const globalPrivacyControl = bridge.accessor(Navigator.getGlobalPrivacyControl, null, .{});

    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{});
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const serviceWorker = bridge.accessor(Navigator.getServiceWorker, null, .{});
    pub const locks = bridge.accessor(Navigator.getLocks, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{});
    pub const geolocation = bridge.accessor(Navigator.getGeolocation, null, .{});
    pub const modelContext = bridge.accessor(Navigator.getModelContext, null, .{});
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{});
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Navigator" {
    try testing.htmlRunner("navigator", .{});
    try testing.htmlRunner("beacon.html", .{ .load_resources = .{ .beacon = true, .iframe = true } });
}

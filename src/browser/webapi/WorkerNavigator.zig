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
const Execution = js.Execution;

const Navigator = @import("Navigator.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");

const WorkerNavigator = @This();

comptime {
    // protect against identity_map conflict (make sure _pad: bool does its job)
    for ([_][]const u8{ "_permissions", "_storage", "_ua_data" }) |name| {
        if (@offsetOf(WorkerNavigator, name) == 0) {
            @compileError(name ++ " aliases the WorkerNavigator");
        }
    }
}

_pad: bool = false,
_permissions: Permissions = .{},
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},

pub const init: WorkerNavigator = .{};

pub fn getUserAgent(_: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return Navigator.getUserAgent(&Navigator.init, exec);
}

pub fn getLanguages(_: *const WorkerNavigator) [2][]const u8 {
    return Navigator.getLanguages(&Navigator.init);
}

pub fn getAppName(_: *const WorkerNavigator) []const u8 {
    return Navigator.getAppName(&Navigator.init);
}

pub fn getAppCodeName(_: *const WorkerNavigator) []const u8 {
    return Navigator.getAppCodeName(&Navigator.init);
}

pub fn getAppVersion(_: *const WorkerNavigator) []const u8 {
    return Navigator.getAppVersion(&Navigator.init);
}

pub fn getLanguage(_: *const WorkerNavigator) []const u8 {
    return Navigator.getLanguage(&Navigator.init);
}

pub fn getOnLine(_: *const WorkerNavigator) bool {
    return Navigator.getOnLine(&Navigator.init);
}

pub fn getHardwareConcurrency(_: *const WorkerNavigator) u32 {
    return Navigator.getHardwareConcurrency(&Navigator.init);
}

pub fn getDeviceMemory(_: *const WorkerNavigator) f64 {
    return Navigator.getDeviceMemory(&Navigator.init);
}

pub fn getVendor(_: *const WorkerNavigator) []const u8 {
    return Navigator.getVendor(&Navigator.init);
}

pub fn getProduct(_: *const WorkerNavigator) []const u8 {
    return Navigator.getProduct(&Navigator.init);
}

pub fn getGlobalPrivacyControl(_: *const WorkerNavigator) bool {
    return Navigator.getGlobalPrivacyControl(&Navigator.init);
}

pub fn getPlatform(_: *const WorkerNavigator) []const u8 {
    return Navigator.getPlatform(&Navigator.init);
}

pub fn getPermissions(self: *WorkerNavigator) *Permissions {
    return &self._permissions;
}

pub fn getStorage(self: *WorkerNavigator) *StorageManager {
    return &self._storage;
}

pub fn getUserAgentData(self: *WorkerNavigator) *NavigatorUAData {
    return &self._ua_data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WorkerNavigator);

    pub const Meta = struct {
        pub const name = "WorkerNavigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const userAgent = bridge.accessor(WorkerNavigator.getUserAgent, null, .{});
    pub const appName = bridge.accessor(WorkerNavigator.getAppName, null, .{});
    pub const appCodeName = bridge.accessor(WorkerNavigator.getAppCodeName, null, .{});
    pub const appVersion = bridge.accessor(WorkerNavigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(WorkerNavigator.getPlatform, null, .{});
    pub const language = bridge.accessor(WorkerNavigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(WorkerNavigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(WorkerNavigator.getOnLine, null, .{});
    pub const hardwareConcurrency = bridge.accessor(WorkerNavigator.getHardwareConcurrency, null, .{});
    pub const deviceMemory = bridge.accessor(WorkerNavigator.getDeviceMemory, null, .{});
    pub const vendor = bridge.accessor(WorkerNavigator.getVendor, null, .{});
    pub const product = bridge.accessor(WorkerNavigator.getProduct, null, .{});
    pub const globalPrivacyControl = bridge.accessor(WorkerNavigator.getGlobalPrivacyControl, null, .{});

    pub const permissions = bridge.accessor(WorkerNavigator.getPermissions, null, .{});
    pub const storage = bridge.accessor(WorkerNavigator.getStorage, null, .{});
    pub const userAgentData = bridge.accessor(WorkerNavigator.getUserAgentData, null, .{});
};

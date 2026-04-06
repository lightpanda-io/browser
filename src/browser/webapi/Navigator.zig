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
const DOMRect = @import("DOMRect.zig");
const PluginArray = @import("PluginArray.zig");
const MimeTypeArray = @import("MimeTypeArray.zig");

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_mime_types: MimeTypeArray = .{},
_user_agent_data: UserAgentData = .{},
_webkit_temporary_storage: StorageQuota = .{ ._request_error_name = "AbortError" },
_webkit_persistent_storage: StorageQuota = .{ ._request_error_name = "AbortError" },
_media_devices: MediaDevices = .{},
_permissions: Permissions = .{},
_connection: NetworkInformation = .{},
_credentials: CredentialsContainer = .{},
_storage_manager: StorageManager = .{},
_media_capabilities: MediaCapabilities = .{},
_user_activation: UserActivation = .{},
_service_worker: ServiceWorkerContainer = .{},
_media_session: MediaSession = .{},
_virtual_keyboard: VirtualKeyboard = .{},
_wake_lock: WakeLock = .{},
_gpu: GPU = .{},
_xr: XR = .{},

    _keyboard: Keyboard = .{},
    _clipboard: Clipboard = .{},
    _presentation: Presentation = .{},
    _storage_buckets: StorageBucketManager = .{},

    _geolocation: Geolocation = .{},
    _bluetooth: Bluetooth = .{},
    _hid: HID = .{},
    _usb: USB = .{},
    _serial: Serial = .{},
    _locks: LockManager = .{},
    _window_controls_overlay: WindowControlsOverlay = .{},

    _scheduling: Scheduling = .{},
    _managed: Managed = .{},
    _login: LoginManager = .{},
    _ink: Ink = .{},
    _device_posture: DevicePosture = .{},
    _protected_audience: ProtectedAudience = .{},

pub const init: Navigator = .{};

pub fn registerTypes() []const type {
    return &.{
        Navigator,
        UserAgentData,
        Brand,
        StorageQuota,
        MediaDevices,
        Permissions,
        NetworkInformation,
        CredentialsContainer,
        StorageManager,
        MediaCapabilities,
        UserActivation,
        ServiceWorkerContainer,
        MediaSession,
        VirtualKeyboard,
        WakeLock,
        GPU,
        XR,
        KeyboardLayoutMap,
        Keyboard,
        Clipboard,
        Presentation,
        StorageBucket,
        StorageBucketManager,
        GeolocationCoordinates,
        GeolocationPosition,
        Geolocation,
        Bluetooth,
        HID,
        USB,
        Serial,
        LockManager,
        WindowControlsOverlay,
        Scheduling,
        Managed,
        LoginManager,
        Ink,
        DevicePosture,
        ProtectedAudience,
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
    _brands: [3]Brand = .{
        .{ ._brand = "Chromium", ._version = "146" },
        .{ ._brand = "Not-A.Brand", ._version = "24" },
        .{ ._brand = "Google Chrome", ._version = "146" },
    },

    const BrandSnapshot = struct {
        brand: []const u8,
        version: []const u8,
    };

    const HighEntropyValues = struct {
        brands: [3]BrandSnapshot,
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
                .{ .brand = self._brands[2]._brand, .version = self._brands[2]._version },
            },
            .mobile = false,
            .architecture = uachArchitecture(),
            .bitness = uachBitness(),
            .model = "",
            .platform = uachPlatformName(),
            .platformVersion = "19.0.0",
            .uaFullVersion = "146.0.7680.178",
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

const MediaDevices = struct {
    pub fn enumerateDevices(_: *const MediaDevices, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub fn getUserMedia(_: *const MediaDevices, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotFoundError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaDevices);

        pub const Meta = struct {
            pub const name = "MediaDevices";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const enumerateDevices = bridge.function(MediaDevices.enumerateDevices, .{});
        pub const getUserMedia = bridge.function(MediaDevices.getUserMedia, .{});
    };
};

const PermissionStateSnapshot = struct {
    state: []const u8,
};

const Permissions = struct {
    pub fn query(_: *const Permissions, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(PermissionStateSnapshot{ .state = "prompt" });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Permissions);

        pub const Meta = struct {
            pub const name = "Permissions";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const query = bridge.function(Permissions.query, .{});
    };
};

const NetworkInformation = struct {
    pub fn getDownlink(_: *const NetworkInformation) f64 {
        return 10;
    }

    pub fn getEffectiveType(_: *const NetworkInformation) []const u8 {
        return "4g";
    }

    pub fn getRtt(_: *const NetworkInformation) u32 {
        return 100;
    }

    pub fn getSaveData(_: *const NetworkInformation) bool {
        return false;
    }

    pub fn getType(_: *const NetworkInformation) []const u8 {
        return "wifi";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NetworkInformation);

        pub const Meta = struct {
            pub const name = "NetworkInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const downlink = bridge.accessor(NetworkInformation.getDownlink, null, .{});
        pub const effectiveType = bridge.accessor(NetworkInformation.getEffectiveType, null, .{});
        pub const rtt = bridge.accessor(NetworkInformation.getRtt, null, .{});
        pub const saveData = bridge.accessor(NetworkInformation.getSaveData, null, .{});
        pub const @"type" = bridge.accessor(NetworkInformation.getType, null, .{});
        pub const onchange = bridge.property(null, .{ .template = false });
    };
};

const CredentialsContainer = struct {
    pub fn create(_: *const CredentialsContainer, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn get(_: *const CredentialsContainer, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn store(_: *const CredentialsContainer, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn preventSilentAccess(_: *const CredentialsContainer, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(void, {}));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CredentialsContainer);

        pub const Meta = struct {
            pub const name = "CredentialsContainer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const create = bridge.function(CredentialsContainer.create, .{});
        pub const get = bridge.function(CredentialsContainer.get, .{});
        pub const store = bridge.function(CredentialsContainer.store, .{});
        pub const preventSilentAccess = bridge.function(CredentialsContainer.preventSilentAccess, .{});
    };
};

const StorageEstimate = struct {
    quota: u64,
    usage: u64,
};

const StorageManager = struct {
    pub fn estimate(_: *const StorageManager, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(StorageEstimate{ .quota = 2 * 1024 * 1024 * 1024, .usage = 0 });
    }

    pub fn persist(_: *const StorageManager, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub fn persisted(_: *const StorageManager, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageManager);

        pub const Meta = struct {
            pub const name = "StorageManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const estimate = bridge.function(StorageManager.estimate, .{});
        pub const persist = bridge.function(StorageManager.persist, .{});
        pub const persisted = bridge.function(StorageManager.persisted, .{});
    };
};

const MediaCapabilitiesInfo = struct {
    supported: bool,
    smooth: bool,
    powerEfficient: bool,
};

const BatteryManagerSnapshot = struct {
    charging: bool,
    chargingTime: u32,
    dischargingTime: u32,
    level: u32,
};

const MediaCapabilities = struct {
    pub fn decodingInfo(_: *const MediaCapabilities, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(MediaCapabilitiesInfo{ .supported = false, .smooth = false, .powerEfficient = false });
    }

    pub fn encodingInfo(_: *const MediaCapabilities, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(MediaCapabilitiesInfo{ .supported = false, .smooth = false, .powerEfficient = false });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaCapabilities);

        pub const Meta = struct {
            pub const name = "MediaCapabilities";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const decodingInfo = bridge.function(MediaCapabilities.decodingInfo, .{});
        pub const encodingInfo = bridge.function(MediaCapabilities.encodingInfo, .{});
    };
};

const UserActivation = struct {
    pub fn getIsActive(_: *const UserActivation) bool {
        return false;
    }

    pub fn getHasBeenActive(_: *const UserActivation) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(UserActivation);

        pub const Meta = struct {
            pub const name = "UserActivation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const isActive = bridge.accessor(UserActivation.getIsActive, null, .{});
        pub const hasBeenActive = bridge.accessor(UserActivation.getHasBeenActive, null, .{});
    };
};

const ServiceWorkerContainer = struct {
    pub fn getReady(_: *const ServiceWorkerContainer, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub fn register(_: *const ServiceWorkerContainer, _: []const u8, _: ?js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub fn getRegistration(_: *const ServiceWorkerContainer, _: ?[]const u8, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn getRegistrations(_: *const ServiceWorkerContainer, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub fn startMessages(_: *const ServiceWorkerContainer) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ServiceWorkerContainer);

        pub const Meta = struct {
            pub const name = "ServiceWorkerContainer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const controller = bridge.property(null, .{ .template = false });
        pub const oncontrollerchange = bridge.property(null, .{ .template = false });
        pub const onmessage = bridge.property(null, .{ .template = false });
        pub const ready = bridge.accessor(ServiceWorkerContainer.getReady, null, .{});
        pub const register = bridge.function(ServiceWorkerContainer.register, .{});
        pub const getRegistration = bridge.function(ServiceWorkerContainer.getRegistration, .{});
        pub const getRegistrations = bridge.function(ServiceWorkerContainer.getRegistrations, .{});
        pub const startMessages = bridge.function(ServiceWorkerContainer.startMessages, .{});
    };
};

const MediaSession = struct {
    pub fn setActionHandler(_: *const MediaSession, _: []const u8, _: ?js.Function.Temp) void {}
    pub fn setPositionState(_: *const MediaSession, _: ?js.Value.Temp) void {}
    pub fn setMicrophoneActive(_: *const MediaSession, _: bool) void {}
    pub fn setCameraActive(_: *const MediaSession, _: bool) void {}
    pub fn setScreenshareActive(_: *const MediaSession, _: bool) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaSession);

        pub const Meta = struct {
            pub const name = "MediaSession";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const metadata = bridge.property(null, .{ .template = false });
        pub const playbackState = bridge.property("none", .{ .template = false });
        pub const setActionHandler = bridge.function(MediaSession.setActionHandler, .{});
        pub const setPositionState = bridge.function(MediaSession.setPositionState, .{});
        pub const setMicrophoneActive = bridge.function(MediaSession.setMicrophoneActive, .{});
        pub const setCameraActive = bridge.function(MediaSession.setCameraActive, .{});
        pub const setScreenshareActive = bridge.function(MediaSession.setScreenshareActive, .{});
    };
};

const VirtualKeyboard = struct {
    pub fn show(_: *const VirtualKeyboard) void {}
    pub fn hide(_: *const VirtualKeyboard) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VirtualKeyboard);

        pub const Meta = struct {
            pub const name = "VirtualKeyboard";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const overlaysContent = bridge.property(false, .{ .template = false });
        pub const boundingRect = bridge.property(null, .{ .template = false });
        pub const ongeometrychange = bridge.property(null, .{ .template = false });
        pub const show = bridge.function(VirtualKeyboard.show, .{});
        pub const hide = bridge.function(VirtualKeyboard.hide, .{});
    };
};

const WakeLock = struct {
    pub fn request(_: *const WakeLock, _: ?[]const u8, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotAllowedError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WakeLock);

        pub const Meta = struct {
            pub const name = "WakeLock";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const request = bridge.function(WakeLock.request, .{});
    };
};

const GPU = struct {
    pub fn requestAdapter(_: *const GPU, _: ?js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn getPreferredCanvasFormat(_: *const GPU) []const u8 {
        return "rgba8unorm";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPU);

        pub const Meta = struct {
            pub const name = "GPU";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const wgslLanguageFeatures = bridge.property(null, .{ .template = false });
        pub const requestAdapter = bridge.function(GPU.requestAdapter, .{});
        pub const getPreferredCanvasFormat = bridge.function(GPU.getPreferredCanvasFormat, .{});
    };
};

const XR = struct {
    pub fn isSessionSupported(_: *const XR, _: []const u8, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub fn requestSession(_: *const XR, _: []const u8, _: ?js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XR);

        pub const Meta = struct {
            pub const name = "XRSystem";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const ondevicechange = bridge.property(null, .{ .template = false });
        pub const isSessionSupported = bridge.function(XR.isSessionSupported, .{});
        pub const requestSession = bridge.function(XR.requestSession, .{});
    };
};

const KeyboardLayoutMap = struct {
    pub fn get(_: *const KeyboardLayoutMap, key: []const u8) []const u8 {
        return key;
    }

    pub fn has(_: *const KeyboardLayoutMap, _: []const u8) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(KeyboardLayoutMap);

        pub const Meta = struct {
            pub const name = "KeyboardLayoutMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const get = bridge.function(KeyboardLayoutMap.get, .{});
        pub const has = bridge.function(KeyboardLayoutMap.has, .{});
    };
};

const Keyboard = struct {
    _layout_map: KeyboardLayoutMap = .{},

    pub fn getLayoutMap(self: *Keyboard) *KeyboardLayoutMap {
        return &self._layout_map;
    }

    pub fn lock(_: *const Keyboard, _: ?js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(void, {}));
    }

    pub fn unlock(_: *const Keyboard) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Keyboard);

        pub const Meta = struct {
            pub const name = "Keyboard";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const lock = bridge.function(Keyboard.lock, .{});
        pub const unlock = bridge.function(Keyboard.unlock, .{});
        pub const getLayoutMap = bridge.function(Keyboard.getLayoutMap, .{});
    };
};

const Clipboard = struct {
    pub fn read(_: *const Clipboard, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotAllowedError"));
    }

    pub fn readText(_: *const Clipboard, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotAllowedError"));
    }

    pub fn write(_: *const Clipboard, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotAllowedError"));
    }

    pub fn writeText(_: *const Clipboard, _: []const u8, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotAllowedError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Clipboard);

        pub const Meta = struct {
            pub const name = "Clipboard";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const read = bridge.function(Clipboard.read, .{});
        pub const readText = bridge.function(Clipboard.readText, .{});
        pub const write = bridge.function(Clipboard.write, .{});
        pub const writeText = bridge.function(Clipboard.writeText, .{});
    };
};

const Presentation = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(Presentation);

        pub const Meta = struct {
            pub const name = "Presentation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const defaultRequest = bridge.property(null, .{ .template = false });
        pub const receiver = bridge.property(null, .{ .template = false });
        pub const onchange = bridge.property(null, .{ .template = false });
    };
};

const StorageBucket = struct {
    pub fn persist(_: *const StorageBucket, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub fn persisted(_: *const StorageBucket, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub fn estimate(_: *const StorageBucket, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(StorageEstimate{ .quota = 2 * 1024 * 1024 * 1024, .usage = 0 });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageBucket);

        pub const Meta = struct {
            pub const name = "StorageBucket";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const indexedDB = bridge.property(null, .{ .template = false });
        pub const locks = bridge.property(null, .{ .template = false });
        pub const caches = bridge.property(null, .{ .template = false });
        pub const estimate = bridge.function(StorageBucket.estimate, .{});
        pub const persist = bridge.function(StorageBucket.persist, .{});
        pub const persisted = bridge.function(StorageBucket.persisted, .{});
    };
};

const StorageBucketManager = struct {
    _bucket: StorageBucket = .{},

    pub fn keys(_: *const StorageBucketManager, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub fn open(self: *StorageBucketManager, _: []const u8) *StorageBucket {
        return &self._bucket;
    }

    pub fn delete(_: *const StorageBucketManager, _: []const u8, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageBucketManager);

        pub const Meta = struct {
            pub const name = "StorageBucketManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const keys = bridge.function(StorageBucketManager.keys, .{});
        pub const open = bridge.function(StorageBucketManager.open, .{});
        pub const delete = bridge.function(StorageBucketManager.delete, .{});
    };
};

const GeolocationCoordinates = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GeolocationCoordinates);

        pub const Meta = struct {
            pub const name = "GeolocationCoordinates";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const latitude = bridge.property(0.0, .{ .template = false });
        pub const longitude = bridge.property(0.0, .{ .template = false });
        pub const accuracy = bridge.property(0.0, .{ .template = false });
        pub const altitude = bridge.property(null, .{ .template = false });
        pub const altitudeAccuracy = bridge.property(null, .{ .template = false });
        pub const heading = bridge.property(null, .{ .template = false });
        pub const speed = bridge.property(null, .{ .template = false });
    };
};

const GeolocationPosition = struct {
    _coords: GeolocationCoordinates = .{},

    pub fn getCoords(self: *GeolocationPosition) *GeolocationCoordinates {
        return &self._coords;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GeolocationPosition);

        pub const Meta = struct {
            pub const name = "GeolocationPosition";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const coords = bridge.accessor(GeolocationPosition.getCoords, null, .{});
        pub const timestamp = bridge.property(0.0, .{ .template = false });
    };
};

const Geolocation = struct {
    pub fn getCurrentPosition(_: *const Geolocation, _: js.Function.Temp, error_callback: ?js.Function.Temp, _: ?js.Value.Temp, page: *Page) !void {
        if (error_callback) |cb| {
            try cb.local(page.js.local.?).call(void, .{DOMException.init(null, "NotAllowedError")});
        }
    }

    pub fn watchPosition(_: *const Geolocation, _: js.Function.Temp, error_callback: ?js.Function.Temp, _: ?js.Value.Temp, page: *Page) !u32 {
        if (error_callback) |cb| {
            try cb.local(page.js.local.?).call(void, .{DOMException.init(null, "NotAllowedError")});
        }
        return 0;
    }

    pub fn clearWatch(_: *const Geolocation, _: u32) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Geolocation);

        pub const Meta = struct {
            pub const name = "Geolocation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getCurrentPosition = bridge.function(Geolocation.getCurrentPosition, .{});
        pub const watchPosition = bridge.function(Geolocation.watchPosition, .{});
        pub const clearWatch = bridge.function(Geolocation.clearWatch, .{});
    };
};

const Bluetooth = struct {
    pub fn getAvailability(_: *const Bluetooth, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(false);
    }

    pub fn requestDevice(_: *const Bluetooth, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotFoundError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Bluetooth);

        pub const Meta = struct {
            pub const name = "Bluetooth";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onavailabilitychanged = bridge.property(null, .{ .template = false });
        pub const getAvailability = bridge.function(Bluetooth.getAvailability, .{});
        pub const requestDevice = bridge.function(Bluetooth.requestDevice, .{});
    };
};

const HID = struct {
    pub fn getDevices(_: *const HID, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub fn requestDevice(_: *const HID, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HID);

        pub const Meta = struct {
            pub const name = "HID";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.property(null, .{ .template = false });
        pub const ondisconnect = bridge.property(null, .{ .template = false });
        pub const getDevices = bridge.function(HID.getDevices, .{});
        pub const requestDevice = bridge.function(HID.requestDevice, .{});
    };
};

const USB = struct {
    pub fn getDevices(_: *const USB, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub fn requestDevice(_: *const USB, _: js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotFoundError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USB);

        pub const Meta = struct {
            pub const name = "USB";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.property(null, .{ .template = false });
        pub const ondisconnect = bridge.property(null, .{ .template = false });
        pub const getDevices = bridge.function(USB.getDevices, .{});
        pub const requestDevice = bridge.function(USB.requestDevice, .{});
    };
};

const Serial = struct {
    pub fn getPorts(_: *const Serial, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise([0]u8{});
    }

    pub fn requestPort(_: *const Serial, _: ?js.Value.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotFoundError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Serial);

        pub const Meta = struct {
            pub const name = "Serial";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.property(null, .{ .template = false });
        pub const ondisconnect = bridge.property(null, .{ .template = false });
        pub const getPorts = bridge.function(Serial.getPorts, .{});
        pub const requestPort = bridge.function(Serial.requestPort, .{});
    };
};

const LockManager = struct {
    pub fn query(_: *const LockManager, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub fn request(_: *const LockManager, _: []const u8, _: js.Function.Temp, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LockManager);

        pub const Meta = struct {
            pub const name = "LockManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const query = bridge.function(LockManager.query, .{});
        pub const request = bridge.function(LockManager.request, .{});
    };
};

const WindowControlsOverlay = struct {
    pub fn getTitlebarAreaRect(_: *const WindowControlsOverlay, page: *Page) !*DOMRect {
        return DOMRect.init(0, 0, 0, 0, page);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WindowControlsOverlay);

        pub const Meta = struct {
            pub const name = "WindowControlsOverlay";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const visible = bridge.property(false, .{ .template = false });
        pub const ongeometrychange = bridge.property(null, .{ .template = false });
        pub const getTitlebarAreaRect = bridge.function(WindowControlsOverlay.getTitlebarAreaRect, .{});
    };
};

const Scheduling = struct {
    pub fn isInputPending(_: *const Scheduling) bool {
        return false;
    }

    pub fn postTask(_: *const Scheduling, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub fn yield(_: *const Scheduling, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Scheduling);

        pub const Meta = struct {
            pub const name = "Scheduler";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const isInputPending = bridge.function(Scheduling.isInputPending, .{});
        pub const postTask = bridge.function(Scheduling.postTask, .{});
        pub const yield = bridge.function(Scheduling.yield, .{});
    };
};

const Managed = struct {
    pub fn getDirectoryId(_: *const Managed, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn getHostname(_: *const Managed, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn getManagedConfiguration(_: *const Managed, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Managed);

        pub const Meta = struct {
            pub const name = "NavigatorManagedData";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getDirectoryId = bridge.function(Managed.getDirectoryId, .{});
        pub const getHostname = bridge.function(Managed.getHostname, .{});
        pub const getManagedConfiguration = bridge.function(Managed.getManagedConfiguration, .{});
    };
};

const LoginManager = struct {
    pub fn setStatus(_: *const LoginManager, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LoginManager);

        pub const Meta = struct {
            pub const name = "NavigatorLogin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const setStatus = bridge.function(LoginManager.setStatus, .{});
    };
};

const Ink = struct {
    pub fn requestPresenter(_: *const Ink, page: *Page) !js.Promise {
        return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Ink);

        pub const Meta = struct {
            pub const name = "Ink";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const requestPresenter = bridge.function(Ink.requestPresenter, .{});
    };
};

const DevicePosture = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(DevicePosture);

        pub const Meta = struct {
            pub const name = "DevicePosture";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.property("continuous", .{ .template = false });
        pub const onchange = bridge.property(null, .{ .template = false });
    };
};

const ProtectedAudience = struct {
    pub fn runAdAuction(_: *const ProtectedAudience, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn joinAdInterestGroup(_: *const ProtectedAudience, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn leaveAdInterestGroup(_: *const ProtectedAudience, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn clearOriginJoinedAdInterestGroups(_: *const ProtectedAudience, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub fn updateAdInterestGroups(_: *const ProtectedAudience, page: *Page) !js.Promise {
        return page.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ProtectedAudience);

        pub const Meta = struct {
            pub const name = "ProtectedAudience";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const runAdAuction = bridge.function(ProtectedAudience.runAdAuction, .{});
        pub const joinAdInterestGroup = bridge.function(ProtectedAudience.joinAdInterestGroup, .{});
        pub const leaveAdInterestGroup = bridge.function(ProtectedAudience.leaveAdInterestGroup, .{});
        pub const clearOriginJoinedAdInterestGroups = bridge.function(ProtectedAudience.clearOriginJoinedAdInterestGroups, .{});
        pub const updateAdInterestGroups = bridge.function(ProtectedAudience.updateAdInterestGroups, .{});
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

pub fn getAppVersion(_: *const Navigator, page: *Page) []const u8 {
    const ua = page._session.browser.app.config.http_headers.user_agent;
    const prefix = "Mozilla/";
    if (std.mem.startsWith(u8, ua, prefix)) {
        return ua[prefix.len..];
    }
    return ua;
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

pub fn canShare(_: *const Navigator, _: ?js.Value.Temp) bool {
    return false;
}

pub fn share(_: *const Navigator, _: ?js.Value.Temp, page: *Page) !js.Promise {
    return page.js.local.?.rejectPromise(DOMException.init(null, "NotAllowedError"));
}

pub fn getBattery(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(BatteryManagerSnapshot{
        .charging = true,
        .chargingTime = @as(u32, 0),
        .dischargingTime = @as(u32, 0),
        .level = @as(u32, 1),
    });
}

pub fn requestMIDIAccess(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
}

pub fn requestMediaKeySystemAccess(_: *const Navigator, _: []const u8, _: js.Value.Temp, page: *Page) !js.Promise {
    return page.js.local.?.rejectPromise(DOMException.init(null, "NotSupportedError"));
}

pub fn getUserMedia(_: *const Navigator, _: js.Value.Temp, _: ?js.Function.Temp, error_callback: ?js.Function.Temp, page: *Page) !void {
    if (error_callback) |cb| {
        try cb.local(page.js.local.?).call(void, .{DOMException.init(null, "NotFoundError")});
    }
}

pub fn webkitGetUserMedia(self: *const Navigator, constraints: js.Value.Temp, success_callback: ?js.Function.Temp, error_callback: ?js.Function.Temp, page: *Page) !void {
    return self.getUserMedia(constraints, success_callback, error_callback, page);
}

pub fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

pub fn getMimeTypes(self: *Navigator) *MimeTypeArray {
    return &self._mime_types;
}

pub fn getMediaDevices(self: *Navigator) *MediaDevices {
    return &self._media_devices;
}

pub fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

pub fn getConnection(self: *Navigator) *NetworkInformation {
    return &self._connection;
}

pub fn getCredentials(self: *Navigator) *CredentialsContainer {
    return &self._credentials;
}

pub fn getStorageManager(self: *Navigator) *StorageManager {
    return &self._storage_manager;
}

pub fn getMediaCapabilities(self: *Navigator) *MediaCapabilities {
    return &self._media_capabilities;
}

pub fn getUserActivation(self: *Navigator) *UserActivation {
    return &self._user_activation;
}

pub fn getServiceWorker(self: *Navigator) *ServiceWorkerContainer {
    return &self._service_worker;
}

pub fn getMediaSession(self: *Navigator) *MediaSession {
    return &self._media_session;
}

pub fn getVirtualKeyboard(self: *Navigator) *VirtualKeyboard {
    return &self._virtual_keyboard;
}

pub fn getWakeLock(self: *Navigator) *WakeLock {
    return &self._wake_lock;
}

pub fn getGPU(self: *Navigator) *GPU {
    return &self._gpu;
}

pub fn getXR(self: *Navigator) *XR {
    return &self._xr;
}

pub fn getKeyboard(self: *Navigator) *Keyboard {
    return &self._keyboard;
}

pub fn getClipboard(self: *Navigator) *Clipboard {
    return &self._clipboard;
}

pub fn getPresentation(self: *Navigator) *Presentation {
    return &self._presentation;
}

pub fn getStorageBuckets(self: *Navigator) *StorageBucketManager {
    return &self._storage_buckets;
}

pub fn getGeolocation(self: *Navigator) *Geolocation {
    return &self._geolocation;
}

pub fn getBluetooth(self: *Navigator) *Bluetooth {
    return &self._bluetooth;
}

pub fn getHID(self: *Navigator) *HID {
    return &self._hid;
}

pub fn getUSB(self: *Navigator) *USB {
    return &self._usb;
}

pub fn getSerial(self: *Navigator) *Serial {
    return &self._serial;
}

pub fn getLocks(self: *Navigator) *LockManager {
    return &self._locks;
}

pub fn getWindowControlsOverlay(self: *Navigator) *WindowControlsOverlay {
    return &self._window_controls_overlay;
}

pub fn getScheduling(self: *Navigator) *Scheduling {
    return &self._scheduling;
}

pub fn getManaged(self: *Navigator) *Managed {
    return &self._managed;
}

pub fn getLogin(self: *Navigator) *LoginManager {
    return &self._login;
}

pub fn getInk(self: *Navigator) *Ink {
    return &self._ink;
}

pub fn getDevicePosture(self: *Navigator) *DevicePosture {
    return &self._device_posture;
}

pub fn getProtectedAudience(self: *Navigator) *ProtectedAudience {
    return &self._protected_audience;
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

pub fn setAppBadge(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn clearAppBadge(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn getInstalledRelatedApps(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise([0]u8{});
}

pub fn getInterestGroupAdAuctionData(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn joinAdInterestGroup(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn leaveAdInterestGroup(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn clearOriginJoinedAdInterestGroups(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn updateAdInterestGroups(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn runAdAuction(_: *const Navigator, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(@as(?u8, null));
}

pub fn canLoadAdAuctionFencedFrame(_: *const Navigator) bool {
    return false;
}

pub fn createAuctionNonce(_: *const Navigator) []const u8 {
    return "00000000-0000-4000-8000-000000000000";
}

pub fn deprecatedReplaceInURN(_: *const Navigator) ?[]const u8 {
    return null;
}

pub fn deprecatedRunAdAuctionEnforcesKAnonymity(_: *const Navigator) bool {
    return false;
}

pub fn deprecatedURNToURL(_: *const Navigator) ?[]const u8 {
    return null;
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
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const language = bridge.property("en-GB", .{ .template = false });
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.property(true, .{ .template = false });
    pub const cookieEnabled = bridge.property(true, .{ .template = false });
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const maxTouchPoints = bridge.property(2, .{ .template = false });
    pub const deviceMemory = bridge.property(8, .{ .template = false });
    pub const mediaDevices = bridge.accessor(Navigator.getMediaDevices, null, .{});
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const connection = bridge.accessor(Navigator.getConnection, null, .{});
    pub const credentials = bridge.accessor(Navigator.getCredentials, null, .{});
    pub const storage = bridge.accessor(Navigator.getStorageManager, null, .{});
    pub const mediaCapabilities = bridge.accessor(Navigator.getMediaCapabilities, null, .{});
    pub const userActivation = bridge.accessor(Navigator.getUserActivation, null, .{});
    pub const serviceWorker = bridge.accessor(Navigator.getServiceWorker, null, .{});
    pub const mediaSession = bridge.accessor(Navigator.getMediaSession, null, .{});
    pub const virtualKeyboard = bridge.accessor(Navigator.getVirtualKeyboard, null, .{});
    pub const wakeLock = bridge.accessor(Navigator.getWakeLock, null, .{});
    pub const gpu = bridge.accessor(Navigator.getGPU, null, .{});
    pub const xr = bridge.accessor(Navigator.getXR, null, .{});
    pub const keyboard = bridge.accessor(Navigator.getKeyboard, null, .{});
    pub const clipboard = bridge.accessor(Navigator.getClipboard, null, .{});
    pub const presentation = bridge.accessor(Navigator.getPresentation, null, .{});
    pub const storageBuckets = bridge.accessor(Navigator.getStorageBuckets, null, .{});
    pub const geolocation = bridge.accessor(Navigator.getGeolocation, null, .{});
    pub const bluetooth = bridge.accessor(Navigator.getBluetooth, null, .{});
    pub const hid = bridge.accessor(Navigator.getHID, null, .{});
    pub const usb = bridge.accessor(Navigator.getUSB, null, .{});
    pub const serial = bridge.accessor(Navigator.getSerial, null, .{});
    pub const locks = bridge.accessor(Navigator.getLocks, null, .{});
    pub const windowControlsOverlay = bridge.accessor(Navigator.getWindowControlsOverlay, null, .{});
    pub const scheduling = bridge.accessor(Navigator.getScheduling, null, .{});
    pub const managed = bridge.accessor(Navigator.getManaged, null, .{});
    pub const login = bridge.accessor(Navigator.getLogin, null, .{});
    pub const ink = bridge.accessor(Navigator.getInk, null, .{});
    pub const devicePosture = bridge.accessor(Navigator.getDevicePosture, null, .{});
    pub const protectedAudience = bridge.accessor(Navigator.getProtectedAudience, null, .{});
    pub const adAuctionComponents = bridge.property(false, .{ .template = false });
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
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .dom_exception = true });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .dom_exception = true });

    // Methods
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const getGamepads = bridge.function(Navigator.getGamepads, .{});
    pub const vibrate = bridge.function(Navigator.vibrate, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{});
    pub const canShare = bridge.function(Navigator.canShare, .{});
    pub const share = bridge.function(Navigator.share, .{});
    pub const getBattery = bridge.function(Navigator.getBattery, .{});
    pub const requestMIDIAccess = bridge.function(Navigator.requestMIDIAccess, .{});
    pub const requestMediaKeySystemAccess = bridge.function(Navigator.requestMediaKeySystemAccess, .{});
    pub const getUserMedia = bridge.function(Navigator.getUserMedia, .{});
    pub const webkitGetUserMedia = bridge.function(Navigator.webkitGetUserMedia, .{});
    pub const setAppBadge = bridge.function(Navigator.setAppBadge, .{});
    pub const clearAppBadge = bridge.function(Navigator.clearAppBadge, .{});
    pub const getInstalledRelatedApps = bridge.function(Navigator.getInstalledRelatedApps, .{});
    pub const getInterestGroupAdAuctionData = bridge.function(Navigator.getInterestGroupAdAuctionData, .{});
    pub const joinAdInterestGroup = bridge.function(Navigator.joinAdInterestGroup, .{});
    pub const leaveAdInterestGroup = bridge.function(Navigator.leaveAdInterestGroup, .{});
    pub const clearOriginJoinedAdInterestGroups = bridge.function(Navigator.clearOriginJoinedAdInterestGroups, .{});
    pub const updateAdInterestGroups = bridge.function(Navigator.updateAdInterestGroups, .{});
    pub const runAdAuction = bridge.function(Navigator.runAdAuction, .{});
    pub const canLoadAdAuctionFencedFrame = bridge.function(Navigator.canLoadAdAuctionFencedFrame, .{});
    pub const createAuctionNonce = bridge.function(Navigator.createAuctionNonce, .{});
    pub const deprecatedReplaceInURN = bridge.function(Navigator.deprecatedReplaceInURN, .{});
    pub const deprecatedRunAdAuctionEnforcesKAnonymity = bridge.function(Navigator.deprecatedRunAdAuctionEnforcesKAnonymity, .{});
    pub const deprecatedURNToURL = bridge.function(Navigator.deprecatedURNToURL, .{});
};








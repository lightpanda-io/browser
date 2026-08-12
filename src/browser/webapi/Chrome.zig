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

//! Minimal `window.chrome` surface matching a normal Chrome page without an
//! extension context.

const lp = @import("lightpanda");

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{ Chrome, Runtime };
}

const Chrome = @This();

_pad: bool = false,
_runtime: Runtime = .{},

pub fn getApp(_: *Chrome, exec: *const js.Execution) !js.Object {
    const value = try exec.js.local.?.exec(
        \\({
        \\  isInstalled: false,
        \\  getDetails() { return null; },
        \\  getIsInstalled() { return false; },
        \\  installState(callback) { callback?.("not_installed"); },
        \\  runningState() { return "cannot_run"; },
        \\  InstallState: {
        \\    DISABLED: "disabled",
        \\    INSTALLED: "installed",
        \\    NOT_INSTALLED: "not_installed",
        \\  },
        \\  RunningState: {
        \\    CANNOT_RUN: "cannot_run",
        \\    READY_TO_RUN: "ready_to_run",
        \\    RUNNING: "running",
        \\  },
        \\})
    , "chrome.app");
    return value.toObject();
}

pub fn getRuntime(self: *Chrome) *Runtime {
    return &self._runtime;
}

/// Navigation timing as Chrome's legacy `chrome.*` APIs report it: wall-clock
/// epoch for the origin, milliseconds-since-origin for the milestones.
const Timing = struct {
    nav_start_ms: f64,
    page_t: f64,
    dcl_t: f64,
    load_t: f64,

    fn get(exec: *const js.Execution) Timing {
        const perf = exec.performance();
        const page_t = perf.now();
        const epoch_ms: f64 = @floatFromInt(lp.datetime.milliTimestamp(.real));
        // Upstream Performance does not yet expose discrete DCL/load milestones
        // for chrome.csi/loadTimes; approximate with performance.now() so the
        // surface stays present and monotone for detectors.
        return .{
            .nav_start_ms = epoch_ms - page_t,
            .page_t = page_t,
            .dcl_t = page_t,
            .load_t = page_t,
        };
    }

    fn epochSeconds(self: *const Timing, offset_ms: f64) f64 {
        return (self.nav_start_ms + offset_ms) / 1000.0;
    }
};

const Runtime = struct {
    _pad: bool = false,

    fn getUndefined(_: *Runtime) void {}
    fn connect(_: *Runtime) void {}
    fn sendMessage(_: *Runtime) void {}

    fn object(exec: *const js.Execution, source: []const u8) !js.Object {
        const value = try exec.js.local.?.exec(source, "chrome.runtime enum");
        return value.toObject();
    }

    fn getContextType(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ BACKGROUND: 'BACKGROUND', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', POPUP: 'POPUP', SIDE_PANEL: 'SIDE_PANEL', TAB: 'TAB' })");
    }

    fn getOnInstalledReason(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ CHROME_UPDATE: 'chrome_update', INSTALL: 'install', SHARED_MODULE_UPDATE: 'shared_module_update', UPDATE: 'update' })");
    }

    fn getOnRestartRequiredReason(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' })");
    }

    fn getPlatformArch(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ ARM: 'arm', ARM64: 'arm64', MIPS: 'mips', MIPS64: 'mips64', RISCV64: 'riscv64', X86_32: 'x86-32', X86_64: 'x86-64' })");
    }

    fn getPlatformNaclArch(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ ARM: 'arm', MIPS: 'mips', MIPS64: 'mips64', X86_32: 'x86-32', X86_64: 'x86-64' })");
    }

    fn getPlatformOs(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ ANDROID: 'android', CROS: 'cros', LINUX: 'linux', MAC: 'mac', OPENBSD: 'openbsd', WIN: 'win' })");
    }

    fn getRequestUpdateCheckStatus(_: *Runtime, exec: *const js.Execution) !js.Object {
        return object(exec, "({ NO_UPDATE: 'no_update', THROTTLED: 'throttled', UPDATE_AVAILABLE: 'update_available' })");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Runtime);

        pub const Meta = struct {
            pub const name = "ChromeRuntime";
            pub const no_interface_object = true;
            pub const no_to_string_tag = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const own_properties = true;
        };

        pub const dynamicId = bridge.accessor(Runtime.getUndefined, null, .{});
        pub const id = bridge.accessor(Runtime.getUndefined, null, .{});
        pub const connect = bridge.function(Runtime.connect, .{});
        pub const sendMessage = bridge.function(Runtime.sendMessage, .{});
        pub const ContextType = bridge.accessor(Runtime.getContextType, null, .{ .cache = .{ .internal = 1 } });
        pub const OnInstalledReason = bridge.accessor(Runtime.getOnInstalledReason, null, .{ .cache = .{ .internal = 2 } });
        pub const OnRestartRequiredReason = bridge.accessor(Runtime.getOnRestartRequiredReason, null, .{ .cache = .{ .internal = 3 } });
        pub const PlatformArch = bridge.accessor(Runtime.getPlatformArch, null, .{ .cache = .{ .internal = 4 } });
        pub const PlatformNaclArch = bridge.accessor(Runtime.getPlatformNaclArch, null, .{ .cache = .{ .internal = 5 } });
        pub const PlatformOs = bridge.accessor(Runtime.getPlatformOs, null, .{ .cache = .{ .internal = 6 } });
        pub const RequestUpdateCheckStatus = bridge.accessor(Runtime.getRequestUpdateCheckStatus, null, .{ .cache = .{ .internal = 7 } });
    };
};

pub fn csi(_: *const Chrome, exec: *const js.Execution) !js.Object {
    const t: Timing = .get(exec);
    const obj = exec.js.local.?.newObject();
    _ = try obj.set("startE", @floor(t.nav_start_ms), .{});
    _ = try obj.set("onloadT", @floor(t.nav_start_ms + t.load_t), .{});
    _ = try obj.set("pageT", t.page_t, .{});
    _ = try obj.set("tran", @as(i32, 15), .{});
    return obj;
}

pub fn loadTimes(_: *const Chrome, exec: *const js.Execution) !js.Object {
    const t: Timing = .get(exec);
    const obj = exec.js.local.?.newObject();
    // ponytail: connect/commit/paint aren't recorded separately, so they're
    // fractions of the DOMContentLoaded offset. Swap for real resource timing
    // if a scanner ever checks the individual gaps rather than "non-zero and
    // ordered".
    _ = try obj.set("requestTime", t.epochSeconds(0), .{});
    _ = try obj.set("startLoadTime", t.epochSeconds(0), .{});
    _ = try obj.set("commitLoadTime", t.epochSeconds(t.dcl_t * 0.25), .{});
    _ = try obj.set("finishDocumentLoadTime", t.epochSeconds(t.dcl_t), .{});
    _ = try obj.set("finishLoadTime", t.epochSeconds(t.load_t), .{});
    _ = try obj.set("firstPaintTime", @as(f64, 0), .{});
    _ = try obj.set("firstPaintAfterLoadTime", @as(f64, 0), .{});
    _ = try obj.set("navigationType", "Other", .{});
    _ = try obj.set("wasFetchedViaSpdy", true, .{});
    _ = try obj.set("wasNpnNegotiated", true, .{});
    _ = try obj.set("npnNegotiatedProtocol", "h3", .{});
    _ = try obj.set("wasAlternateProtocolAvailable", false, .{});
    _ = try obj.set("connectionInfo", "h3", .{});
    return obj;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Chrome);

    pub const Meta = struct {
        pub const name = "Chrome";
        // Real Chrome has no `window.Chrome` interface object.
        pub const no_interface_object = true;
        // `window.chrome` is a plain object, not a Web IDL interface instance.
        pub const no_to_string_tag = true;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const own_properties = true;
    };

    pub const loadTimes = bridge.function(Chrome.loadTimes, .{});
    pub const csi = bridge.function(Chrome.csi, .{});
    pub const app = bridge.accessor(Chrome.getApp, null, .{ .cache = .{ .internal = 1 } });
    pub const runtime = bridge.accessor(Chrome.getRuntime, null, .{ .cache = .{ .internal = 2 } });
};

const testing = @import("../../testing.zig");

test "WebApi: stealth" {
    try testing.htmlRunner("stealth", .{});
}

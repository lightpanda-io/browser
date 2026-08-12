// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! `navigator.getBattery()` and `navigator.connection`. Chrome exposes both;
//! their absence is a headless heuristic. Values are derived from the
//! fingerprint seed so one instance stays self-consistent for a session and
//! different seeds look like different machines.

const std = @import("std");

const js = @import("../js/js.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ BatteryManager, NetworkInformation };
}

fn profileSeed(exec: *const Execution) u64 {
    return exec.session.browser.app.config.fingerprint_profile.noise_seed;
}

pub fn networkDownlink(seed: u64) f64 {
    const step: f64 = @floatFromInt((seed >> 16) % 21);
    return 5.0 + step * 0.25;
}

pub fn networkRtt(seed: u64) u32 {
    return @intCast(((seed >> 24) % 8) * 25 + 25);
}

pub const BatteryManager = struct {
    // Padding to avoid zero-size struct pointer collisions.
    _pad: bool = false,

    pub fn getCharging(_: *const BatteryManager, exec: *const Execution) bool {
        return profileSeed(exec) % 2 == 0;
    }

    /// 0.05 steps in [0.35, 1.0] — Chrome quantizes level to 1% and desktops
    /// spend most of their time in the upper half of the range.
    pub fn getLevel(_: *const BatteryManager, exec: *const Execution) f64 {
        const step: f64 = @floatFromInt((profileSeed(exec) >> 8) % 14);
        return 0.35 + step * 0.05;
    }

    pub fn getChargingTime(self: *const BatteryManager, exec: *const Execution) f64 {
        if (!self.getCharging(exec)) return std.math.inf(f64);
        const level = self.getLevel(exec);
        if (level >= 1.0) return 0;
        // Roughly a 2h charge from empty, rounded to Chrome's 15-minute grid.
        return @round((1.0 - level) * 7200.0 / 900.0) * 900.0;
    }

    pub fn getDischargingTime(self: *const BatteryManager, exec: *const Execution) f64 {
        if (self.getCharging(exec)) return std.math.inf(f64);
        return @round(self.getLevel(exec) * 21600.0 / 900.0) * 900.0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BatteryManager);

        pub const Meta = struct {
            pub const name = "BatteryManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const charging = bridge.accessor(BatteryManager.getCharging, null, .{});
        pub const chargingTime = bridge.accessor(BatteryManager.getChargingTime, null, .{});
        pub const dischargingTime = bridge.accessor(BatteryManager.getDischargingTime, null, .{});
        pub const level = bridge.accessor(BatteryManager.getLevel, null, .{});
    };
};

pub const NetworkInformation = struct {
    // Padding to avoid zero-size struct pointer collisions.
    _pad: bool = false,
    _on_change: ?js.Function.Global = null,

    pub fn getOnChange(self: *const NetworkInformation) ?js.Function.Global {
        return self._on_change;
    }

    pub fn setOnChange(self: *NetworkInformation, callback: ?js.Function.Global) void {
        self._on_change = callback;
    }

    /// Chrome clamps `effectiveType` to "4g" on any decent broadband link, and
    /// that's what the overwhelming majority of real desktops report.
    pub fn getEffectiveType(_: *const NetworkInformation) []const u8 {
        return "4g";
    }

    /// Chrome caps downlink at 10 Mbps and quantizes it to 0.05 steps.
    pub fn getDownlink(_: *const NetworkInformation, exec: *const Execution) f64 {
        return networkDownlink(profileSeed(exec));
    }

    /// Chrome quantizes rtt to 25ms buckets.
    pub fn getRtt(_: *const NetworkInformation, exec: *const Execution) u32 {
        return networkRtt(profileSeed(exec));
    }

    pub fn getSaveData(_: *const NetworkInformation) bool {
        return false;
    }

    /// The connection technology's theoretical ceiling, which Chrome reports
    /// as Infinity on wifi/ethernet. The value carries almost no information —
    /// its *absence* is the signal (CreepJS counts `noDownlinkMax` toward
    /// "like headless"), so what matters is that the property exists.
    pub fn getDownlinkMax(_: *const NetworkInformation) f64 {
        return std.math.inf(f64);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NetworkInformation);

        pub const Meta = struct {
            pub const name = "NetworkInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const onchange = bridge.accessor(NetworkInformation.getOnChange, NetworkInformation.setOnChange, .{});
        pub const effectiveType = bridge.accessor(NetworkInformation.getEffectiveType, null, .{});
        pub const rtt = bridge.accessor(NetworkInformation.getRtt, null, .{});
        pub const downlink = bridge.accessor(NetworkInformation.getDownlink, null, .{});
        pub const saveData = bridge.accessor(NetworkInformation.getSaveData, null, .{});
    };
};

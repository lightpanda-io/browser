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

const builtin = @import("builtin");

const Config = @import("../../Config.zig");
const js = @import("../js/js.zig");
const Execution = js.Execution;

const NavigatorUAData = @This();

_pad: bool = false,

const Brand = struct {
    brand: []const u8,
    version: []const u8,
};

pub fn getBrands(_: *const NavigatorUAData, exec: *const Execution) []const Brand {
    return brandList(exec);
}

pub fn getMobile(_: *const NavigatorUAData) bool {
    return false;
}

pub fn getPlatform(_: *const NavigatorUAData, exec: *const Execution) []const u8 {
    return platformName(exec);
}

pub fn toJSON(_: *const NavigatorUAData, exec: *const Execution) struct {
    brands: []const Brand,
    mobile: bool,
    platform: []const u8,
} {
    return .{
        .mobile = false,
        .brands = brandList(exec),
        .platform = platformName(exec),
    };
}

pub fn getHighEntropyValues(_: *const NavigatorUAData, hints: []const []const u8, exec: *const Execution) !js.Promise {
    // This should always return `brands` + `mobile` + `platform` and then whatever
    // "hints" field is requested (assuming the browser has permission), but it's
    // also valid to just return everything.

    _ = hints;

    const stealth = exec.session.browser.app.config.stealth();
    const fp = exec.session.browser.app.config.fingerprint_profile;
    return exec.js.local.?.resolvePromise(.{
        .brands = brandList(exec),
        .mobile = false,
        .platform = platformName(exec),
        .architecture = uaArchitecture(),
        .bitness = uaBitness(),
        .model = "",
        .platformVersion = if (stealth) Config.HttpHeaders.secChUaPlatformVersion(fp.platform) else "",
        .uaFullVersion = if (stealth) Config.HttpHeaders.stealth_ua_full_version else "1.0.0.0",
        .fullVersionList = brandList(exec),
        .wow64 = false,
        .formFactor = [_][]const u8{"Desktop"},
    });
}

fn brandList(exec: *const Execution) []const Brand {
    const stealth = exec.session.browser.app.config.stealth();
    if (stealth) {
        const out = comptime blk: {
            const src = &Config.HttpHeaders.brands_stealth;
            var arr: [src.len]Brand = undefined;
            for (src, 0..) |b, i| {
                arr[i] = .{ .brand = b.brand, .version = b.version };
            }
            const final = arr;
            break :blk final;
        };
        return &out;
    }
    const out = comptime blk: {
        const src = &Config.HttpHeaders.brands;
        var arr: [src.len]Brand = undefined;
        for (src, 0..) |b, i| {
            arr[i] = .{ .brand = b.brand, .version = b.version };
        }
        const final = arr;
        break :blk final;
    };
    return &out;
}

fn platformName(exec: *const Execution) []const u8 {
    return switch (exec.session.browser.app.config.fingerprint_profile.platform) {
        .windows => "Windows",
        .macos => "macOS",
        .linux => "Linux",
    };
}

fn uaPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macOS",
        .windows => "Windows",
        .linux => "Linux",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

fn uaArchitecture() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => "x86",
        .aarch64, .aarch64_be, .arm, .armeb => "arm",
        else => "",
    };
}

fn uaBitness() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .powerpc64, .powerpc64le, .riscv64 => "64",
        else => "32",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigatorUAData);

    pub const Meta = struct {
        pub const name = "NavigatorUAData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const brands = bridge.accessor(NavigatorUAData.getBrands, null, .{});
    pub const mobile = bridge.accessor(NavigatorUAData.getMobile, null, .{});
    pub const platform = bridge.accessor(NavigatorUAData.getPlatform, null, .{});
    pub const toJSON = bridge.function(NavigatorUAData.toJSON, .{});
    pub const getHighEntropyValues = bridge.function(NavigatorUAData.getHighEntropyValues, .{});
};

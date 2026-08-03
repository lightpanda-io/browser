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

const std = @import("std");
const builtin = @import("builtin");

const Config = @import("../../Config.zig");
const js = @import("../js/js.zig");
const Execution = js.Execution;

_pad: bool = false,

const Brand = Config.HttpHeaders.Brand;

pub fn getBrands(_: *const @This(), exec: *const Execution) !js.Value {
    return frozenBrandList(exec, false);
}

pub fn getMobile(_: *const @This()) bool {
    return false;
}

pub fn getPlatform(_: *const @This()) []const u8 {
    return uaPlatform();
}

pub fn toJSON(_: *const @This()) struct {
    brands: []const Brand,
    mobile: bool,
    platform: []const u8,
} {
    return .{
        .mobile = false,
        .brands = brandList(),
        .platform = uaPlatform(),
    };
}

pub fn getHighEntropyValues(_: *const @This(), hints: []const []const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const values = local.newObject();
    _ = try values.set("brands", try frozenBrandList(exec, false), .{});
    _ = try values.set("mobile", false, .{});
    _ = try values.set("platform", uaPlatform(), .{});

    for (hints) |hint| {
        if (std.mem.eql(u8, hint, "architecture")) {
            _ = try values.set("architecture", uaArchitecture(), .{});
        } else if (std.mem.eql(u8, hint, "bitness")) {
            _ = try values.set("bitness", uaBitness(), .{});
        } else if (std.mem.eql(u8, hint, "formFactors")) {
            _ = try values.set("formFactors", [_][]const u8{"Desktop"}, .{});
        } else if (std.mem.eql(u8, hint, "fullVersionList")) {
            _ = try values.set("fullVersionList", try frozenBrandList(exec, true), .{});
        } else if (std.mem.eql(u8, hint, "model")) {
            _ = try values.set("model", "", .{});
        } else if (std.mem.eql(u8, hint, "platformVersion")) {
            _ = try values.set("platformVersion", "", .{});
        } else if (std.mem.eql(u8, hint, "uaFullVersion")) {
            _ = try values.set("uaFullVersion", "1.0.0.0", .{});
        } else if (std.mem.eql(u8, hint, "wow64")) {
            _ = try values.set("wow64", false, .{});
        }
    }

    return local.resolvePromise(values);
}

fn brandList() []const Brand {
    return &Config.HttpHeaders.brands;
}

fn fullBrandList() []const Brand {
    return &Config.HttpHeaders.full_brands;
}

fn frozenBrandList(exec: *const Execution, full: bool) !js.Value {
    const context = exec.js;
    const local = context.local.?;
    const cache = if (full) &context.navigator_full_brands else &context.navigator_brands;
    if (cache.*) |brands| {
        return brands.local(local);
    }

    const source = if (full) fullBrandList() else brandList();
    const frozen = try local.freeze(try local.zigValueToJs(source, .{}));
    cache.* = try frozen.persist();
    return frozen;
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

const Self = @This();

pub const JsApi = struct {
    pub const bridge = js.Bridge(Self);

    pub const Meta = struct {
        pub const name = "NavigatorUAData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const brands = bridge.accessor(getBrands, null, .{});
    pub const mobile = bridge.accessor(getMobile, null, .{});
    pub const platform = bridge.accessor(getPlatform, null, .{});
    pub const toJSON = bridge.function(toJSONFn, .{});
    pub const getHighEntropyValues = bridge.function(getHighEntropyValuesFn, .{});
};

// Aliases avoid JsApi field names shadowing the free functions.
const toJSONFn = toJSON;
const getHighEntropyValuesFn = getHighEntropyValues;

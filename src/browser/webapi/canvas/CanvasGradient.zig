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

const js = @import("../../js/js.zig");

/// Fingerprint-grade CanvasGradient: records color stops for hash stability
/// without performing real rasterization.
const CanvasGradient = @This();

_kind: Kind,
_seed: u64,

pub const Kind = enum { linear, radial, conic };

pub fn addColorStop(self: *CanvasGradient, offset: f64, color_str: []const u8) void {
    // Clamp offset into [0,1] like browsers; invalid colors still mix into seed.
    const o = @max(0.0, @min(1.0, offset));
    self._seed = mix(self._seed, @as(u64, @bitCast(o)));
    self._seed = mixBytes(self._seed, color_str);
}

pub fn seed(self: *const CanvasGradient) u64 {
    return self._seed;
}

fn mix(h: u64, v: u64) u64 {
    var x = h ^ v;
    x *%= 0x100000001b3;
    return x;
}

fn mixBytes(h: u64, bytes: []const u8) u64 {
    var x = h;
    for (bytes) |b| {
        x ^= b;
        x *%= 0x100000001b3;
    }
    return x;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasGradient);

    pub const Meta = struct {
        pub const name = "CanvasGradient";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const addColorStop = bridge.function(CanvasGradient.addColorStop, .{});
};

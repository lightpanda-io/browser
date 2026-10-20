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

// https://webaudio.github.io/web-audio-api/#PeriodicWave

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Wavetable = @import("dsp/PeriodicWave.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const PeriodicWave = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_table: Wavetable,

pub const Options = struct {
    disableNormalization: bool = false,
    imag: ?[]const f32 = null,
    real: ?[]const f32 = null,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*PeriodicWave {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*PeriodicWave {
    const page = context._page;
    const arena = try page.getArena(.medium, "PeriodicWave");
    errdefer arena.release();
    const allocator = arena.allocator();

    var real: []const f32 = undefined;
    var imag: []const f32 = undefined;
    if (options.real) |r| {
        real = r;
        imag = options.imag orelse try zeros(allocator, r.len);
    } else if (options.imag) |i| {
        real = try zeros(allocator, i.len);
        imag = i;
    } else {
        real = &.{ 0, 0 };
        imag = &.{ 0, 1 };
    }
    for (real) |v| if (std.math.isFinite(v) == false) return error.TypeError;
    for (imag) |v| if (std.math.isFinite(v) == false) return error.TypeError;
    if (real.len != imag.len or real.len < 2) {
        return error.IndexSizeError;
    }

    const self = try allocator.create(PeriodicWave);
    self.* = .{
        ._arena = arena,
        ._table = try .initCoefficients(allocator, context._sample_rate, real, imag, options.disableNormalization),
    };
    return self;
}

fn zeros(allocator: std.mem.Allocator, len: usize) ![]const f32 {
    const values = try allocator.alloc(f32, len);
    @memset(values, 0);
    return values;
}

pub fn deinit(self: *PeriodicWave, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *PeriodicWave) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *PeriodicWave, page: *Page) void {
    self._rc.release(self, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PeriodicWave);

    pub const Meta = struct {
        pub const name = "PeriodicWave";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PeriodicWave.constructor, .{});
};

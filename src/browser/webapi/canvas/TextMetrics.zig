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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Execution = js.Execution;

/// Metrics from the deterministic text model in text_measure.zig: ascent is
/// 0.8em and descent 0.2em, as in a generic sans-serif face.
const TextMetrics = @This();

_rc: lp.RC = .{},
_width: f64,
_ascent: f64,
_descent: f64,

pub fn init(width: f64, font_size: f64, exec: *const Execution) !*TextMetrics {
    return exec._factory.create(TextMetrics{
        ._width = width,
        ._ascent = font_size * 0.8,
        ._descent = font_size * 0.2,
    });
}

pub fn deinit(self: *TextMetrics, page: *Page) void {
    page.factory.destroy(self);
}

pub fn acquireRef(self: *TextMetrics) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *TextMetrics, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getWidth(self: *const TextMetrics) f64 {
    return self._width;
}

pub fn getAscent(self: *const TextMetrics) f64 {
    return self._ascent;
}

pub fn getDescent(self: *const TextMetrics) f64 {
    return self._descent;
}

pub fn getIdeographicBaseline(self: *const TextMetrics) f64 {
    return -self._descent;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextMetrics);

    pub const Meta = struct {
        pub const name = "TextMetrics";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(TextMetrics.getWidth, null, .{});
    pub const actualBoundingBoxLeft = bridge.property(0.0, .{ .template = false });
    pub const actualBoundingBoxRight = bridge.accessor(TextMetrics.getWidth, null, .{});
    pub const actualBoundingBoxAscent = bridge.accessor(TextMetrics.getAscent, null, .{});
    pub const actualBoundingBoxDescent = bridge.accessor(TextMetrics.getDescent, null, .{});
    pub const fontBoundingBoxAscent = bridge.accessor(TextMetrics.getAscent, null, .{});
    pub const fontBoundingBoxDescent = bridge.accessor(TextMetrics.getDescent, null, .{});
    pub const emHeightAscent = bridge.accessor(TextMetrics.getAscent, null, .{});
    pub const emHeightDescent = bridge.accessor(TextMetrics.getDescent, null, .{});
    pub const hangingBaseline = bridge.accessor(TextMetrics.getAscent, null, .{});
    pub const alphabeticBaseline = bridge.property(0.0, .{ .template = false });
    pub const ideographicBaseline = bridge.accessor(TextMetrics.getIdeographicBaseline, null, .{});
};

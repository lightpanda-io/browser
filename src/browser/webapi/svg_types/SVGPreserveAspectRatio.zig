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

const SVGPreserveAspectRatio = @This();

const js = @import("../../js/js.zig");

_align: u16,
_meet_or_slice: u16,

pub fn getAlign(self: *const SVGPreserveAspectRatio) u16 {
    return self._align;
}

pub fn setAlign(self: *SVGPreserveAspectRatio, value: u16) void {
    self._align = value;
}

pub fn getMeetOrSlice(self: *const SVGPreserveAspectRatio) u16 {
    return self._meet_or_slice;
}

pub fn setMeetOrSlice(self: *SVGPreserveAspectRatio, value: u16) void {
    self._meet_or_slice = value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGPreserveAspectRatio);

    pub const Meta = struct {
        pub const name = "SVGPreserveAspectRatio";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_PRESERVEASPECTRATIO_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_NONE = bridge.property(1, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMINYMIN = bridge.property(2, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMIDYMIN = bridge.property(3, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMAXYMIN = bridge.property(4, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMINYMID = bridge.property(5, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMIDYMID = bridge.property(6, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMAXYMID = bridge.property(7, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMINYMAX = bridge.property(8, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMIDYMAX = bridge.property(9, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMAXYMAX = bridge.property(10, .{ .template = true });

    pub const SVG_MEETORSLICE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_MEETORSLICE_MEET = bridge.property(1, .{ .template = true });
    pub const SVG_MEETORSLICE_SLICE = bridge.property(2, .{ .template = true });

    pub const @"align" = bridge.accessor(SVGPreserveAspectRatio.getAlign, SVGPreserveAspectRatio.setAlign, .{});
    pub const meetOrSlice = bridge.accessor(SVGPreserveAspectRatio.getMeetOrSlice, SVGPreserveAspectRatio.setMeetOrSlice, .{});
};

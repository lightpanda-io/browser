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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");

const AnimatedEnumeration = @This();

_element: *Element,
_attr_name: lp.String,
_entries: []const Entry,
_default_value: u16,

pub const Entry = struct {
    keyword: []const u8,
    value: u16,
};

const unit_entries = [_]Entry{
    .{ .keyword = "userSpaceOnUse", .value = 1 },
    .{ .keyword = "objectBoundingBox", .value = 2 },
};
const marker_unit_entries = [_]Entry{
    .{ .keyword = "userSpaceOnUse", .value = 1 },
    .{ .keyword = "strokeWidth", .value = 2 },
};
const spread_entries = [_]Entry{
    .{ .keyword = "pad", .value = 1 },
    .{ .keyword = "reflect", .value = 2 },
    .{ .keyword = "repeat", .value = 3 },
};
const length_adjust_entries = [_]Entry{
    .{ .keyword = "spacing", .value = 1 },
    .{ .keyword = "spacingAndGlyphs", .value = 2 },
};
const text_path_method_entries = [_]Entry{
    .{ .keyword = "align", .value = 1 },
    .{ .keyword = "stretch", .value = 2 },
};
const text_path_spacing_entries = [_]Entry{
    .{ .keyword = "auto", .value = 1 },
    .{ .keyword = "exact", .value = 2 },
};

pub const Kind = enum {
    clip_path_units,
    gradient_units,
    spread_method,
    marker_units,
    mask_units,
    mask_content_units,
    pattern_units,
    pattern_content_units,
    length_adjust,
    text_path_method,
    text_path_spacing,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .clip_path_units => .wrap("clipPathUnits"),
            .gradient_units => .wrap("gradientUnits"),
            .spread_method => .wrap("spreadMethod"),
            .marker_units => .wrap("markerUnits"),
            .mask_units => .wrap("maskUnits"),
            .mask_content_units => .wrap("maskContentUnits"),
            .pattern_units => .wrap("patternUnits"),
            .pattern_content_units => .wrap("patternContentUnits"),
            .length_adjust => .wrap("lengthAdjust"),
            .text_path_method => .wrap("method"),
            .text_path_spacing => .wrap("spacing"),
        };
    }

    fn entries(self: Kind) []const Entry {
        return switch (self) {
            .marker_units => &marker_unit_entries,
            .spread_method => &spread_entries,
            .length_adjust => &length_adjust_entries,
            .text_path_method => &text_path_method_entries,
            .text_path_spacing => &text_path_spacing_entries,
            else => &unit_entries,
        };
    }

    fn defaultValue(self: Kind) u16 {
        return switch (self) {
            .clip_path_units,
            .mask_content_units,
            .pattern_content_units,
            .spread_method,
            .length_adjust,
            .text_path_method,
            => 1,
            else => 2,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedEnumeration);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedEnumeration {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_enumerations.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_enumerations.remove(key);
        gop.value_ptr.* = try create(
            element,
            kind.attributeName(),
            kind.entries(),
            kind.defaultValue(),
            frame,
        );
    }
    return gop.value_ptr.*;
}

pub fn create(
    element: *Element,
    attr_name: lp.String,
    entries: []const Entry,
    default_value: u16,
    frame: *Frame,
) !*AnimatedEnumeration {
    return frame._factory.create(AnimatedEnumeration{
        ._element = element,
        ._attr_name = attr_name,
        ._entries = entries,
        ._default_value = default_value,
    });
}

pub fn getBaseVal(self: *const AnimatedEnumeration) u16 {
    // Keywords match exactly — Chrome and Firefox reject even whitespace-padded
    // values, and both answer an unrecognized value with the initial value.
    const raw = self._element.getAttributeSafe(self._attr_name) orelse return self._default_value;
    for (self._entries) |entry| {
        if (std.mem.eql(u8, raw, entry.keyword)) return entry.value;
    }
    return self._default_value;
}

pub fn setBaseVal(self: *AnimatedEnumeration, value: u16, frame: *Frame) !void {
    for (self._entries) |entry| {
        if (entry.value == value) {
            try self._element.setAttributeSafe(self._attr_name, .wrap(entry.keyword), frame);
            return;
        }
    }
    return error.TypeError;
}

pub fn getAnimVal(self: *const AnimatedEnumeration) u16 {
    return self.getBaseVal();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedEnumeration);

    pub const Meta = struct {
        pub const name = "SVGAnimatedEnumeration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedEnumeration.getBaseVal, AnimatedEnumeration.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedEnumeration.getAnimVal, null, .{});
};

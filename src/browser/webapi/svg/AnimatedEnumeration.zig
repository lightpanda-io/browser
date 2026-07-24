// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

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

    fn attributeName(self: Kind, frame: *Frame) !lp.String {
        const name = switch (self) {
            .clip_path_units => "clipPathUnits",
            .gradient_units => "gradientUnits",
            .spread_method => "spreadMethod",
            .marker_units => "markerUnits",
            .mask_units => "maskUnits",
            .mask_content_units => "maskContentUnits",
            .pattern_units => "patternUnits",
            .pattern_content_units => "patternContentUnits",
            .length_adjust => "lengthAdjust",
            .text_path_method => "method",
            .text_path_spacing => "spacing",
        };
        return lp.String.init(frame.arena, name, .{ .dupe = false });
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
            try kind.attributeName(frame),
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
    const raw = self._element.getAttributeSafe(self._attr_name) orelse return self._default_value;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
    for (self._entries) |entry| {
        if (std.mem.eql(u8, trimmed, entry.keyword)) return entry.value;
    }
    return 0;
}

pub fn setBaseVal(self: *AnimatedEnumeration, value: u16, frame: *Frame) !void {
    for (self._entries) |entry| {
        if (entry.value == value) {
            try self._element.setAttributeSafe(self._attr_name, lp.String.wrap(entry.keyword), frame);
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

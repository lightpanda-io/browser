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

const std = @import("std");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const CSS = @This();
_pad: bool = false,

pub const init: CSS = .{};

pub fn parseDimension(value: []const u8) ?f64 {
    if (value.len == 0) {
        return null;
    }

    var num_str = value;
    if (std.mem.endsWith(u8, value, "px")) {
        num_str = value[0 .. value.len - 2];
    }

    return std.fmt.parseFloat(f64, num_str) catch null;
}

/// Escapes a CSS identifier string
/// https://drafts.csswg.org/cssom/#the-css.escape()-method
pub fn escape(_: *const CSS, value: []const u8, page: *Page) ![]const u8 {
    if (value.len == 0) {
        return "";
    }

    const first = value[0];
    if (first == '-' and value.len == 1) {
        return "\\-";
    }

    // Count how many characters we need for the output
    var out_len: usize = escapeLen(true, first);
    for (value[1..], 0..) |c, i| {
        // Second char (i==0) is a digit and first is '-', needs hex escape
        if (i == 0 and first == '-' and c >= '0' and c <= '9') {
            out_len += 2 + hexDigitsNeeded(c);
        } else {
            out_len += escapeLen(false, c);
        }
    }

    if (out_len == value.len) {
        return value;
    }

    const result = try page.call_arena.alloc(u8, out_len);
    var pos: usize = 0;

    if (needsEscape(true, first)) {
        pos = writeEscape(true, result, first);
    } else {
        result[0] = first;
        pos = 1;
    }

    for (value[1..], 0..) |c, i| {
        // Second char (i==0) is a digit and first is '-', needs hex escape
        if (i == 0 and first == '-' and c >= '0' and c <= '9') {
            result[pos] = '\\';
            const hex_str = std.fmt.bufPrint(result[pos + 1 ..], "{x} ", .{c}) catch unreachable;
            pos += 1 + hex_str.len;
        } else if (!needsEscape(false, c)) {
            result[pos] = c;
            pos += 1;
        } else {
            pos += writeEscape(false, result[pos..], c);
        }
    }

    return result;
}

/// CSS.supports() - validates CSS property/value pairs against Chrome 131's
/// supported set. Uses a positive allowlist of all 639 properties Chrome 131
/// supports, compiled into a perfect hash table at comptime (~15KB binary, O(1)).
/// Anti-bot systems test for browser-specific properties (e.g. -moz-appearance
/// is Firefox-only) and expect correct false results.
pub fn supports(_: *const CSS, property_or_condition: []const u8, value: ?[]const u8) bool {
    if (value) |_| {
        // Two-argument form: CSS.supports(property, value)
        return chrome131_properties.has(property_or_condition);
    }
    // One-argument form: CSS.supports(conditionText)
    // Parse out the property name from the condition and check it.
    // For simple conditions like "(display: flex)", extract the property.
    return !containsUnsupportedCondition(property_or_condition);
}

fn containsUnsupportedCondition(condition: []const u8) bool {
    // Check if the condition string contains browser-specific prefixes
    // that Chrome doesn't support
    if (std.mem.indexOf(u8, condition, "-moz-") != null) return true;
    if (std.mem.indexOf(u8, condition, "-ms-") != null) return true;
    if (std.mem.indexOf(u8, condition, "-o-") != null) return true;
    return false;
}

// Chrome 131 CSS properties allowlist (639 properties).
// Source: github.com/known-css/known-css-properties/source/browsers/chrome-131.0.json
// Compiled into a perfect hash table at comptime by Zig.
const chrome131_properties = std.StaticStringMap(void).initComptime(.{
        .{ "-webkit-align-content", {} },
        .{ "-webkit-align-items", {} },
        .{ "-webkit-align-self", {} },
        .{ "-webkit-animation", {} },
        .{ "-webkit-animation-delay", {} },
        .{ "-webkit-animation-direction", {} },
        .{ "-webkit-animation-duration", {} },
        .{ "-webkit-animation-fill-mode", {} },
        .{ "-webkit-animation-iteration-count", {} },
        .{ "-webkit-animation-name", {} },
        .{ "-webkit-animation-play-state", {} },
        .{ "-webkit-animation-timing-function", {} },
        .{ "-webkit-app-region", {} },
        .{ "-webkit-appearance", {} },
        .{ "-webkit-backface-visibility", {} },
        .{ "-webkit-background-clip", {} },
        .{ "-webkit-background-origin", {} },
        .{ "-webkit-background-size", {} },
        .{ "-webkit-border-after", {} },
        .{ "-webkit-border-after-color", {} },
        .{ "-webkit-border-after-style", {} },
        .{ "-webkit-border-after-width", {} },
        .{ "-webkit-border-before", {} },
        .{ "-webkit-border-before-color", {} },
        .{ "-webkit-border-before-style", {} },
        .{ "-webkit-border-before-width", {} },
        .{ "-webkit-border-bottom-left-radius", {} },
        .{ "-webkit-border-bottom-right-radius", {} },
        .{ "-webkit-border-end", {} },
        .{ "-webkit-border-end-color", {} },
        .{ "-webkit-border-end-style", {} },
        .{ "-webkit-border-end-width", {} },
        .{ "-webkit-border-horizontal-spacing", {} },
        .{ "-webkit-border-image", {} },
        .{ "-webkit-border-radius", {} },
        .{ "-webkit-border-start", {} },
        .{ "-webkit-border-start-color", {} },
        .{ "-webkit-border-start-style", {} },
        .{ "-webkit-border-start-width", {} },
        .{ "-webkit-border-top-left-radius", {} },
        .{ "-webkit-border-top-right-radius", {} },
        .{ "-webkit-border-vertical-spacing", {} },
        .{ "-webkit-box-align", {} },
        .{ "-webkit-box-decoration-break", {} },
        .{ "-webkit-box-direction", {} },
        .{ "-webkit-box-flex", {} },
        .{ "-webkit-box-ordinal-group", {} },
        .{ "-webkit-box-orient", {} },
        .{ "-webkit-box-pack", {} },
        .{ "-webkit-box-reflect", {} },
        .{ "-webkit-box-shadow", {} },
        .{ "-webkit-box-sizing", {} },
        .{ "-webkit-clip-path", {} },
        .{ "-webkit-column-break-after", {} },
        .{ "-webkit-column-break-before", {} },
        .{ "-webkit-column-break-inside", {} },
        .{ "-webkit-column-count", {} },
        .{ "-webkit-column-gap", {} },
        .{ "-webkit-column-rule", {} },
        .{ "-webkit-column-rule-color", {} },
        .{ "-webkit-column-rule-style", {} },
        .{ "-webkit-column-rule-width", {} },
        .{ "-webkit-column-span", {} },
        .{ "-webkit-column-width", {} },
        .{ "-webkit-columns", {} },
        .{ "-webkit-filter", {} },
        .{ "-webkit-flex", {} },
        .{ "-webkit-flex-basis", {} },
        .{ "-webkit-flex-direction", {} },
        .{ "-webkit-flex-flow", {} },
        .{ "-webkit-flex-grow", {} },
        .{ "-webkit-flex-shrink", {} },
        .{ "-webkit-flex-wrap", {} },
        .{ "-webkit-font-feature-settings", {} },
        .{ "-webkit-font-smoothing", {} },
        .{ "-webkit-hyphenate-character", {} },
        .{ "-webkit-justify-content", {} },
        .{ "-webkit-line-break", {} },
        .{ "-webkit-line-clamp", {} },
        .{ "-webkit-locale", {} },
        .{ "-webkit-logical-height", {} },
        .{ "-webkit-logical-width", {} },
        .{ "-webkit-margin-after", {} },
        .{ "-webkit-margin-before", {} },
        .{ "-webkit-margin-end", {} },
        .{ "-webkit-margin-start", {} },
        .{ "-webkit-mask", {} },
        .{ "-webkit-mask-box-image", {} },
        .{ "-webkit-mask-box-image-outset", {} },
        .{ "-webkit-mask-box-image-repeat", {} },
        .{ "-webkit-mask-box-image-slice", {} },
        .{ "-webkit-mask-box-image-source", {} },
        .{ "-webkit-mask-box-image-width", {} },
        .{ "-webkit-mask-clip", {} },
        .{ "-webkit-mask-composite", {} },
        .{ "-webkit-mask-image", {} },
        .{ "-webkit-mask-origin", {} },
        .{ "-webkit-mask-position", {} },
        .{ "-webkit-mask-position-x", {} },
        .{ "-webkit-mask-position-y", {} },
        .{ "-webkit-mask-repeat", {} },
        .{ "-webkit-mask-size", {} },
        .{ "-webkit-max-logical-height", {} },
        .{ "-webkit-max-logical-width", {} },
        .{ "-webkit-min-logical-height", {} },
        .{ "-webkit-min-logical-width", {} },
        .{ "-webkit-opacity", {} },
        .{ "-webkit-order", {} },
        .{ "-webkit-padding-after", {} },
        .{ "-webkit-padding-before", {} },
        .{ "-webkit-padding-end", {} },
        .{ "-webkit-padding-start", {} },
        .{ "-webkit-perspective", {} },
        .{ "-webkit-perspective-origin", {} },
        .{ "-webkit-perspective-origin-x", {} },
        .{ "-webkit-perspective-origin-y", {} },
        .{ "-webkit-print-color-adjust", {} },
        .{ "-webkit-rtl-ordering", {} },
        .{ "-webkit-ruby-position", {} },
        .{ "-webkit-shape-image-threshold", {} },
        .{ "-webkit-shape-margin", {} },
        .{ "-webkit-shape-outside", {} },
        .{ "-webkit-tap-highlight-color", {} },
        .{ "-webkit-text-combine", {} },
        .{ "-webkit-text-decorations-in-effect", {} },
        .{ "-webkit-text-emphasis", {} },
        .{ "-webkit-text-emphasis-color", {} },
        .{ "-webkit-text-emphasis-position", {} },
        .{ "-webkit-text-emphasis-style", {} },
        .{ "-webkit-text-fill-color", {} },
        .{ "-webkit-text-orientation", {} },
        .{ "-webkit-text-security", {} },
        .{ "-webkit-text-size-adjust", {} },
        .{ "-webkit-text-stroke", {} },
        .{ "-webkit-text-stroke-color", {} },
        .{ "-webkit-text-stroke-width", {} },
        .{ "-webkit-transform", {} },
        .{ "-webkit-transform-origin", {} },
        .{ "-webkit-transform-origin-x", {} },
        .{ "-webkit-transform-origin-y", {} },
        .{ "-webkit-transform-origin-z", {} },
        .{ "-webkit-transform-style", {} },
        .{ "-webkit-transition", {} },
        .{ "-webkit-transition-delay", {} },
        .{ "-webkit-transition-duration", {} },
        .{ "-webkit-transition-property", {} },
        .{ "-webkit-transition-timing-function", {} },
        .{ "-webkit-user-drag", {} },
        .{ "-webkit-user-modify", {} },
        .{ "-webkit-user-select", {} },
        .{ "-webkit-writing-mode", {} },
        .{ "accent-color", {} },
        .{ "additive-symbols", {} },
        .{ "align-content", {} },
        .{ "align-items", {} },
        .{ "align-self", {} },
        .{ "alignment-baseline", {} },
        .{ "all", {} },
        .{ "anchor-name", {} },
        .{ "anchor-scope", {} },
        .{ "animation", {} },
        .{ "animation-composition", {} },
        .{ "animation-delay", {} },
        .{ "animation-direction", {} },
        .{ "animation-duration", {} },
        .{ "animation-fill-mode", {} },
        .{ "animation-iteration-count", {} },
        .{ "animation-name", {} },
        .{ "animation-play-state", {} },
        .{ "animation-range", {} },
        .{ "animation-range-end", {} },
        .{ "animation-range-start", {} },
        .{ "animation-timeline", {} },
        .{ "animation-timing-function", {} },
        .{ "app-region", {} },
        .{ "appearance", {} },
        .{ "ascent-override", {} },
        .{ "aspect-ratio", {} },
        .{ "backdrop-filter", {} },
        .{ "backface-visibility", {} },
        .{ "background", {} },
        .{ "background-attachment", {} },
        .{ "background-blend-mode", {} },
        .{ "background-clip", {} },
        .{ "background-color", {} },
        .{ "background-image", {} },
        .{ "background-origin", {} },
        .{ "background-position", {} },
        .{ "background-position-x", {} },
        .{ "background-position-y", {} },
        .{ "background-repeat", {} },
        .{ "background-size", {} },
        .{ "base-palette", {} },
        .{ "baseline-shift", {} },
        .{ "baseline-source", {} },
        .{ "block-size", {} },
        .{ "border", {} },
        .{ "border-block", {} },
        .{ "border-block-color", {} },
        .{ "border-block-end", {} },
        .{ "border-block-end-color", {} },
        .{ "border-block-end-style", {} },
        .{ "border-block-end-width", {} },
        .{ "border-block-start", {} },
        .{ "border-block-start-color", {} },
        .{ "border-block-start-style", {} },
        .{ "border-block-start-width", {} },
        .{ "border-block-style", {} },
        .{ "border-block-width", {} },
        .{ "border-bottom", {} },
        .{ "border-bottom-color", {} },
        .{ "border-bottom-left-radius", {} },
        .{ "border-bottom-right-radius", {} },
        .{ "border-bottom-style", {} },
        .{ "border-bottom-width", {} },
        .{ "border-collapse", {} },
        .{ "border-color", {} },
        .{ "border-end-end-radius", {} },
        .{ "border-end-start-radius", {} },
        .{ "border-image", {} },
        .{ "border-image-outset", {} },
        .{ "border-image-repeat", {} },
        .{ "border-image-slice", {} },
        .{ "border-image-source", {} },
        .{ "border-image-width", {} },
        .{ "border-inline", {} },
        .{ "border-inline-color", {} },
        .{ "border-inline-end", {} },
        .{ "border-inline-end-color", {} },
        .{ "border-inline-end-style", {} },
        .{ "border-inline-end-width", {} },
        .{ "border-inline-start", {} },
        .{ "border-inline-start-color", {} },
        .{ "border-inline-start-style", {} },
        .{ "border-inline-start-width", {} },
        .{ "border-inline-style", {} },
        .{ "border-inline-width", {} },
        .{ "border-left", {} },
        .{ "border-left-color", {} },
        .{ "border-left-style", {} },
        .{ "border-left-width", {} },
        .{ "border-radius", {} },
        .{ "border-right", {} },
        .{ "border-right-color", {} },
        .{ "border-right-style", {} },
        .{ "border-right-width", {} },
        .{ "border-spacing", {} },
        .{ "border-start-end-radius", {} },
        .{ "border-start-start-radius", {} },
        .{ "border-style", {} },
        .{ "border-top", {} },
        .{ "border-top-color", {} },
        .{ "border-top-left-radius", {} },
        .{ "border-top-right-radius", {} },
        .{ "border-top-style", {} },
        .{ "border-top-width", {} },
        .{ "border-width", {} },
        .{ "bottom", {} },
        .{ "box-decoration-break", {} },
        .{ "box-shadow", {} },
        .{ "box-sizing", {} },
        .{ "break-after", {} },
        .{ "break-before", {} },
        .{ "break-inside", {} },
        .{ "buffered-rendering", {} },
        .{ "caption-side", {} },
        .{ "caret-color", {} },
        .{ "clear", {} },
        .{ "clip", {} },
        .{ "clip-path", {} },
        .{ "clip-rule", {} },
        .{ "color", {} },
        .{ "color-interpolation", {} },
        .{ "color-interpolation-filters", {} },
        .{ "color-rendering", {} },
        .{ "color-scheme", {} },
        .{ "column-count", {} },
        .{ "column-fill", {} },
        .{ "column-gap", {} },
        .{ "column-rule", {} },
        .{ "column-rule-color", {} },
        .{ "column-rule-style", {} },
        .{ "column-rule-width", {} },
        .{ "column-span", {} },
        .{ "column-width", {} },
        .{ "columns", {} },
        .{ "contain", {} },
        .{ "contain-intrinsic-block-size", {} },
        .{ "contain-intrinsic-height", {} },
        .{ "contain-intrinsic-inline-size", {} },
        .{ "contain-intrinsic-size", {} },
        .{ "contain-intrinsic-width", {} },
        .{ "container", {} },
        .{ "container-name", {} },
        .{ "container-type", {} },
        .{ "content", {} },
        .{ "content-visibility", {} },
        .{ "counter-increment", {} },
        .{ "counter-reset", {} },
        .{ "counter-set", {} },
        .{ "cursor", {} },
        .{ "cx", {} },
        .{ "cy", {} },
        .{ "d", {} },
        .{ "descent-override", {} },
        .{ "direction", {} },
        .{ "display", {} },
        .{ "dominant-baseline", {} },
        .{ "empty-cells", {} },
        .{ "fallback", {} },
        .{ "field-sizing", {} },
        .{ "fill", {} },
        .{ "fill-opacity", {} },
        .{ "fill-rule", {} },
        .{ "filter", {} },
        .{ "flex", {} },
        .{ "flex-basis", {} },
        .{ "flex-direction", {} },
        .{ "flex-flow", {} },
        .{ "flex-grow", {} },
        .{ "flex-shrink", {} },
        .{ "flex-wrap", {} },
        .{ "float", {} },
        .{ "flood-color", {} },
        .{ "flood-opacity", {} },
        .{ "font", {} },
        .{ "font-display", {} },
        .{ "font-family", {} },
        .{ "font-feature-settings", {} },
        .{ "font-kerning", {} },
        .{ "font-optical-sizing", {} },
        .{ "font-palette", {} },
        .{ "font-size", {} },
        .{ "font-size-adjust", {} },
        .{ "font-stretch", {} },
        .{ "font-style", {} },
        .{ "font-synthesis", {} },
        .{ "font-synthesis-small-caps", {} },
        .{ "font-synthesis-style", {} },
        .{ "font-synthesis-weight", {} },
        .{ "font-variant", {} },
        .{ "font-variant-alternates", {} },
        .{ "font-variant-caps", {} },
        .{ "font-variant-east-asian", {} },
        .{ "font-variant-emoji", {} },
        .{ "font-variant-ligatures", {} },
        .{ "font-variant-numeric", {} },
        .{ "font-variant-position", {} },
        .{ "font-variation-settings", {} },
        .{ "font-weight", {} },
        .{ "forced-color-adjust", {} },
        .{ "gap", {} },
        .{ "grid", {} },
        .{ "grid-area", {} },
        .{ "grid-auto-columns", {} },
        .{ "grid-auto-flow", {} },
        .{ "grid-auto-rows", {} },
        .{ "grid-column", {} },
        .{ "grid-column-end", {} },
        .{ "grid-column-gap", {} },
        .{ "grid-column-start", {} },
        .{ "grid-gap", {} },
        .{ "grid-row", {} },
        .{ "grid-row-end", {} },
        .{ "grid-row-gap", {} },
        .{ "grid-row-start", {} },
        .{ "grid-template", {} },
        .{ "grid-template-areas", {} },
        .{ "grid-template-columns", {} },
        .{ "grid-template-rows", {} },
        .{ "height", {} },
        .{ "hyphenate-character", {} },
        .{ "hyphenate-limit-chars", {} },
        .{ "hyphens", {} },
        .{ "image-orientation", {} },
        .{ "image-rendering", {} },
        .{ "inherits", {} },
        .{ "initial-letter", {} },
        .{ "initial-value", {} },
        .{ "inline-size", {} },
        .{ "inset", {} },
        .{ "inset-block", {} },
        .{ "inset-block-end", {} },
        .{ "inset-block-start", {} },
        .{ "inset-inline", {} },
        .{ "inset-inline-end", {} },
        .{ "inset-inline-start", {} },
        .{ "interpolate-size", {} },
        .{ "isolation", {} },
        .{ "justify-content", {} },
        .{ "justify-items", {} },
        .{ "justify-self", {} },
        .{ "left", {} },
        .{ "letter-spacing", {} },
        .{ "lighting-color", {} },
        .{ "line-break", {} },
        .{ "line-gap-override", {} },
        .{ "line-height", {} },
        .{ "list-style", {} },
        .{ "list-style-image", {} },
        .{ "list-style-position", {} },
        .{ "list-style-type", {} },
        .{ "margin", {} },
        .{ "margin-block", {} },
        .{ "margin-block-end", {} },
        .{ "margin-block-start", {} },
        .{ "margin-bottom", {} },
        .{ "margin-inline", {} },
        .{ "margin-inline-end", {} },
        .{ "margin-inline-start", {} },
        .{ "margin-left", {} },
        .{ "margin-right", {} },
        .{ "margin-top", {} },
        .{ "marker", {} },
        .{ "marker-end", {} },
        .{ "marker-mid", {} },
        .{ "marker-start", {} },
        .{ "mask", {} },
        .{ "mask-clip", {} },
        .{ "mask-composite", {} },
        .{ "mask-image", {} },
        .{ "mask-mode", {} },
        .{ "mask-origin", {} },
        .{ "mask-position", {} },
        .{ "mask-repeat", {} },
        .{ "mask-size", {} },
        .{ "mask-type", {} },
        .{ "math-depth", {} },
        .{ "math-shift", {} },
        .{ "math-style", {} },
        .{ "max-block-size", {} },
        .{ "max-height", {} },
        .{ "max-inline-size", {} },
        .{ "max-width", {} },
        .{ "min-block-size", {} },
        .{ "min-height", {} },
        .{ "min-inline-size", {} },
        .{ "min-width", {} },
        .{ "mix-blend-mode", {} },
        .{ "navigation", {} },
        .{ "negative", {} },
        .{ "object-fit", {} },
        .{ "object-position", {} },
        .{ "object-view-box", {} },
        .{ "offset", {} },
        .{ "offset-anchor", {} },
        .{ "offset-distance", {} },
        .{ "offset-path", {} },
        .{ "offset-position", {} },
        .{ "offset-rotate", {} },
        .{ "opacity", {} },
        .{ "order", {} },
        .{ "orphans", {} },
        .{ "outline", {} },
        .{ "outline-color", {} },
        .{ "outline-offset", {} },
        .{ "outline-style", {} },
        .{ "outline-width", {} },
        .{ "overflow", {} },
        .{ "overflow-anchor", {} },
        .{ "overflow-clip-margin", {} },
        .{ "overflow-wrap", {} },
        .{ "overflow-x", {} },
        .{ "overflow-y", {} },
        .{ "overlay", {} },
        .{ "override-colors", {} },
        .{ "overscroll-behavior", {} },
        .{ "overscroll-behavior-block", {} },
        .{ "overscroll-behavior-inline", {} },
        .{ "overscroll-behavior-x", {} },
        .{ "overscroll-behavior-y", {} },
        .{ "pad", {} },
        .{ "padding", {} },
        .{ "padding-block", {} },
        .{ "padding-block-end", {} },
        .{ "padding-block-start", {} },
        .{ "padding-bottom", {} },
        .{ "padding-inline", {} },
        .{ "padding-inline-end", {} },
        .{ "padding-inline-start", {} },
        .{ "padding-left", {} },
        .{ "padding-right", {} },
        .{ "padding-top", {} },
        .{ "page", {} },
        .{ "page-break-after", {} },
        .{ "page-break-before", {} },
        .{ "page-break-inside", {} },
        .{ "page-orientation", {} },
        .{ "paint-order", {} },
        .{ "perspective", {} },
        .{ "perspective-origin", {} },
        .{ "place-content", {} },
        .{ "place-items", {} },
        .{ "place-self", {} },
        .{ "pointer-events", {} },
        .{ "position", {} },
        .{ "position-anchor", {} },
        .{ "position-area", {} },
        .{ "position-try", {} },
        .{ "position-try-fallbacks", {} },
        .{ "position-try-order", {} },
        .{ "position-visibility", {} },
        .{ "prefix", {} },
        .{ "quotes", {} },
        .{ "r", {} },
        .{ "range", {} },
        .{ "resize", {} },
        .{ "right", {} },
        .{ "rotate", {} },
        .{ "row-gap", {} },
        .{ "ruby-align", {} },
        .{ "ruby-position", {} },
        .{ "rx", {} },
        .{ "ry", {} },
        .{ "scale", {} },
        .{ "scroll-behavior", {} },
        .{ "scroll-margin", {} },
        .{ "scroll-margin-block", {} },
        .{ "scroll-margin-block-end", {} },
        .{ "scroll-margin-block-start", {} },
        .{ "scroll-margin-bottom", {} },
        .{ "scroll-margin-inline", {} },
        .{ "scroll-margin-inline-end", {} },
        .{ "scroll-margin-inline-start", {} },
        .{ "scroll-margin-left", {} },
        .{ "scroll-margin-right", {} },
        .{ "scroll-margin-top", {} },
        .{ "scroll-padding", {} },
        .{ "scroll-padding-block", {} },
        .{ "scroll-padding-block-end", {} },
        .{ "scroll-padding-block-start", {} },
        .{ "scroll-padding-bottom", {} },
        .{ "scroll-padding-inline", {} },
        .{ "scroll-padding-inline-end", {} },
        .{ "scroll-padding-inline-start", {} },
        .{ "scroll-padding-left", {} },
        .{ "scroll-padding-right", {} },
        .{ "scroll-padding-top", {} },
        .{ "scroll-snap-align", {} },
        .{ "scroll-snap-stop", {} },
        .{ "scroll-snap-type", {} },
        .{ "scroll-timeline", {} },
        .{ "scroll-timeline-axis", {} },
        .{ "scroll-timeline-name", {} },
        .{ "scrollbar-color", {} },
        .{ "scrollbar-gutter", {} },
        .{ "scrollbar-width", {} },
        .{ "shape-image-threshold", {} },
        .{ "shape-margin", {} },
        .{ "shape-outside", {} },
        .{ "shape-rendering", {} },
        .{ "size", {} },
        .{ "size-adjust", {} },
        .{ "speak", {} },
        .{ "speak-as", {} },
        .{ "src", {} },
        .{ "stop-color", {} },
        .{ "stop-opacity", {} },
        .{ "stroke", {} },
        .{ "stroke-dasharray", {} },
        .{ "stroke-dashoffset", {} },
        .{ "stroke-linecap", {} },
        .{ "stroke-linejoin", {} },
        .{ "stroke-miterlimit", {} },
        .{ "stroke-opacity", {} },
        .{ "stroke-width", {} },
        .{ "suffix", {} },
        .{ "symbols", {} },
        .{ "syntax", {} },
        .{ "system", {} },
        .{ "tab-size", {} },
        .{ "table-layout", {} },
        .{ "text-align", {} },
        .{ "text-align-last", {} },
        .{ "text-anchor", {} },
        .{ "text-combine-upright", {} },
        .{ "text-decoration", {} },
        .{ "text-decoration-color", {} },
        .{ "text-decoration-line", {} },
        .{ "text-decoration-skip-ink", {} },
        .{ "text-decoration-style", {} },
        .{ "text-decoration-thickness", {} },
        .{ "text-emphasis", {} },
        .{ "text-emphasis-color", {} },
        .{ "text-emphasis-position", {} },
        .{ "text-emphasis-style", {} },
        .{ "text-indent", {} },
        .{ "text-orientation", {} },
        .{ "text-overflow", {} },
        .{ "text-rendering", {} },
        .{ "text-shadow", {} },
        .{ "text-size-adjust", {} },
        .{ "text-spacing-trim", {} },
        .{ "text-transform", {} },
        .{ "text-underline-offset", {} },
        .{ "text-underline-position", {} },
        .{ "text-wrap", {} },
        .{ "text-wrap-mode", {} },
        .{ "text-wrap-style", {} },
        .{ "timeline-scope", {} },
        .{ "top", {} },
        .{ "touch-action", {} },
        .{ "transform", {} },
        .{ "transform-box", {} },
        .{ "transform-origin", {} },
        .{ "transform-style", {} },
        .{ "transition", {} },
        .{ "transition-behavior", {} },
        .{ "transition-delay", {} },
        .{ "transition-duration", {} },
        .{ "transition-property", {} },
        .{ "transition-timing-function", {} },
        .{ "translate", {} },
        .{ "types", {} },
        .{ "unicode-bidi", {} },
        .{ "unicode-range", {} },
        .{ "user-select", {} },
        .{ "vector-effect", {} },
        .{ "vertical-align", {} },
        .{ "view-timeline", {} },
        .{ "view-timeline-axis", {} },
        .{ "view-timeline-inset", {} },
        .{ "view-timeline-name", {} },
        .{ "view-transition-class", {} },
        .{ "view-transition-name", {} },
        .{ "visibility", {} },
        .{ "white-space", {} },
        .{ "white-space-collapse", {} },
        .{ "widows", {} },
        .{ "width", {} },
        .{ "will-change", {} },
        .{ "word-break", {} },
        .{ "word-spacing", {} },
        .{ "word-wrap", {} },
        .{ "writing-mode", {} },
        .{ "x", {} },
        .{ "y", {} },
        .{ "z-index", {} },
        .{ "zoom", {} },
});

fn escapeLen(comptime is_first: bool, c: u8) usize {
    if (needsEscape(is_first, c) == false) {
        return 1;
    }
    if (c == 0) {
        return "\u{FFFD}".len;
    }
    if (isHexEscape(c) or ((comptime is_first) and c >= '0' and c <= '9')) {
        // Will be escaped as \XX (backslash + 1-6 hex digits + space)
        return 2 + hexDigitsNeeded(c);
    }
    // Escaped as \C (backslash + character)
    return 2;
}

fn needsEscape(comptime is_first: bool, c: u8) bool {
    if (comptime is_first) {
        if (c >= '0' and c <= '9') {
            return true;
        }
    }

    // Characters that need escaping
    return switch (c) {
        0...0x1F, 0x7F => true,
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '`', '{', '|', '}', '~' => true,
        ' ' => true,
        else => false,
    };
}

fn isHexEscape(c: u8) bool {
    return (c >= 0x00 and c <= 0x1F) or c == 0x7F;
}

fn hexDigitsNeeded(c: u8) usize {
    if (c < 0x10) {
        return 1;
    }
    return 2;
}

fn writeEscape(comptime is_first: bool, buf: []u8, c: u8) usize {
    if (c == 0) {
        // NULL character becomes replacement character (no backslash)
        const replacement = "\u{FFFD}";
        @memcpy(buf[0..replacement.len], replacement);
        return replacement.len;
    }

    buf[0] = '\\';
    var data = buf[1..];

    if (isHexEscape(c) or ((comptime is_first) and c >= '0' and c <= '9')) {
        const hex_str = std.fmt.bufPrint(data, "{x} ", .{c}) catch unreachable;
        return 1 + hex_str.len;
    }

    data[0] = c;
    return 2;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSS);

    pub const Meta = struct {
        pub const name = "Css";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const escape = bridge.function(CSS.escape, .{});
    pub const supports = bridge.function(CSS.supports, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: CSS" {
    try testing.htmlRunner("css.html", .{});
}

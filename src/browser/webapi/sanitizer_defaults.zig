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

//  default configuration for Sanitizer

const std = @import("std");

const global_event_handlers = @import("global_event_handlers.zig");

const Namespace = @import("Sanitizer.zig").Namespace;

pub const xhtml_ns = "http://www.w3.org/1999/xhtml";
pub const svg_ns = "http://www.w3.org/2000/svg";
pub const mathml_ns = "http://www.w3.org/1998/Math/MathML";
pub const xlink_ns = "http://www.w3.org/1999/xlink";
pub const xml_ns = "http://www.w3.org/XML/1998/namespace";
pub const xmlns_ns = "http://www.w3.org/2000/xmlns/";

// A name as a table writes it, and as one arrives from JS: still a plain slice,
// because a `Sanitizer.Name` holds an `lp.String`, which cannot be built at
// comptime past 12 bytes -- and `animateTransform` and friends are longer.
// `Sanitizer.staticName` / `ownName` turn one of these into a `Name`.
pub const Name = struct {
    name: []const u8,
    namespace: Namespace,
};

pub const Element = struct {
    name: []const u8,
    namespace: Namespace,
    attributes: []const Name = &.{},
};

// https://html.spec.whatwg.org/#built-in-non-replaceable-elements-list
pub const non_replaceable_elements: []const Name = &.{
    .{ .name = "html", .namespace = .xhtml },
    .{ .name = "svg", .namespace = .svg },
    .{ .name = "math", .namespace = .mathml },
};

// https://wicg.github.io/sanitizer-api/#built-in-safe-default-configuration
pub const default_elements: []const Element = &.{
    .{ .name = "math", .namespace = .mathml },
    .{ .name = "merror", .namespace = .mathml },
    .{ .name = "mfrac", .namespace = .mathml },
    .{ .name = "mi", .namespace = .mathml },
    .{ .name = "mmultiscripts", .namespace = .mathml },
    .{ .name = "mn", .namespace = .mathml },
    .{ .name = "mo", .namespace = .mathml, .attributes = &.{ .{ .name = "fence", .namespace = .none }, .{ .name = "form", .namespace = .none }, .{ .name = "largeop", .namespace = .none }, .{ .name = "lspace", .namespace = .none }, .{ .name = "maxsize", .namespace = .none }, .{ .name = "minsize", .namespace = .none }, .{ .name = "movablelimits", .namespace = .none }, .{ .name = "rspace", .namespace = .none }, .{ .name = "separator", .namespace = .none }, .{ .name = "stretchy", .namespace = .none }, .{ .name = "symmetric", .namespace = .none } } },
    .{ .name = "mover", .namespace = .mathml, .attributes = &.{.{ .name = "accent", .namespace = .none }} },
    .{ .name = "mpadded", .namespace = .mathml, .attributes = &.{ .{ .name = "depth", .namespace = .none }, .{ .name = "height", .namespace = .none }, .{ .name = "lspace", .namespace = .none }, .{ .name = "voffset", .namespace = .none }, .{ .name = "width", .namespace = .none } } },
    .{ .name = "mphantom", .namespace = .mathml },
    .{ .name = "mprescripts", .namespace = .mathml },
    .{ .name = "mroot", .namespace = .mathml },
    .{ .name = "mrow", .namespace = .mathml },
    .{ .name = "ms", .namespace = .mathml },
    .{ .name = "mspace", .namespace = .mathml, .attributes = &.{ .{ .name = "depth", .namespace = .none }, .{ .name = "height", .namespace = .none }, .{ .name = "width", .namespace = .none } } },
    .{ .name = "msqrt", .namespace = .mathml },
    .{ .name = "mstyle", .namespace = .mathml },
    .{ .name = "msub", .namespace = .mathml },
    .{ .name = "msubsup", .namespace = .mathml },
    .{ .name = "msup", .namespace = .mathml },
    .{ .name = "mtable", .namespace = .mathml },
    .{ .name = "mtd", .namespace = .mathml, .attributes = &.{ .{ .name = "columnspan", .namespace = .none }, .{ .name = "rowspan", .namespace = .none } } },
    .{ .name = "mtext", .namespace = .mathml },
    .{ .name = "mtr", .namespace = .mathml },
    .{ .name = "munder", .namespace = .mathml, .attributes = &.{.{ .name = "accentunder", .namespace = .none }} },
    .{ .name = "munderover", .namespace = .mathml, .attributes = &.{ .{ .name = "accent", .namespace = .none }, .{ .name = "accentunder", .namespace = .none } } },
    .{ .name = "semantics", .namespace = .mathml },
    .{ .name = "a", .namespace = .xhtml, .attributes = &.{ .{ .name = "href", .namespace = .none }, .{ .name = "hreflang", .namespace = .none }, .{ .name = "type", .namespace = .none } } },
    .{ .name = "abbr", .namespace = .xhtml },
    .{ .name = "address", .namespace = .xhtml },
    .{ .name = "article", .namespace = .xhtml },
    .{ .name = "aside", .namespace = .xhtml },
    .{ .name = "b", .namespace = .xhtml },
    .{ .name = "bdi", .namespace = .xhtml },
    .{ .name = "bdo", .namespace = .xhtml },
    .{ .name = "blockquote", .namespace = .xhtml, .attributes = &.{.{ .name = "cite", .namespace = .none }} },
    .{ .name = "body", .namespace = .xhtml },
    .{ .name = "br", .namespace = .xhtml },
    .{ .name = "caption", .namespace = .xhtml },
    .{ .name = "cite", .namespace = .xhtml },
    .{ .name = "code", .namespace = .xhtml },
    .{ .name = "col", .namespace = .xhtml, .attributes = &.{.{ .name = "span", .namespace = .none }} },
    .{ .name = "colgroup", .namespace = .xhtml, .attributes = &.{.{ .name = "span", .namespace = .none }} },
    .{ .name = "data", .namespace = .xhtml, .attributes = &.{.{ .name = "value", .namespace = .none }} },
    .{ .name = "dd", .namespace = .xhtml },
    .{ .name = "del", .namespace = .xhtml, .attributes = &.{ .{ .name = "cite", .namespace = .none }, .{ .name = "datetime", .namespace = .none } } },
    .{ .name = "dfn", .namespace = .xhtml },
    .{ .name = "div", .namespace = .xhtml },
    .{ .name = "dl", .namespace = .xhtml },
    .{ .name = "dt", .namespace = .xhtml },
    .{ .name = "em", .namespace = .xhtml },
    .{ .name = "figcaption", .namespace = .xhtml },
    .{ .name = "figure", .namespace = .xhtml },
    .{ .name = "footer", .namespace = .xhtml },
    .{ .name = "h1", .namespace = .xhtml },
    .{ .name = "h2", .namespace = .xhtml },
    .{ .name = "h3", .namespace = .xhtml },
    .{ .name = "h4", .namespace = .xhtml },
    .{ .name = "h5", .namespace = .xhtml },
    .{ .name = "h6", .namespace = .xhtml },
    .{ .name = "head", .namespace = .xhtml },
    .{ .name = "header", .namespace = .xhtml },
    .{ .name = "hgroup", .namespace = .xhtml },
    .{ .name = "hr", .namespace = .xhtml },
    .{ .name = "html", .namespace = .xhtml },
    .{ .name = "i", .namespace = .xhtml },
    .{ .name = "ins", .namespace = .xhtml, .attributes = &.{ .{ .name = "cite", .namespace = .none }, .{ .name = "datetime", .namespace = .none } } },
    .{ .name = "kbd", .namespace = .xhtml },
    .{ .name = "li", .namespace = .xhtml, .attributes = &.{.{ .name = "value", .namespace = .none }} },
    .{ .name = "main", .namespace = .xhtml },
    .{ .name = "mark", .namespace = .xhtml },
    .{ .name = "menu", .namespace = .xhtml },
    .{ .name = "nav", .namespace = .xhtml },
    .{ .name = "ol", .namespace = .xhtml, .attributes = &.{ .{ .name = "reversed", .namespace = .none }, .{ .name = "start", .namespace = .none }, .{ .name = "type", .namespace = .none } } },
    .{ .name = "p", .namespace = .xhtml },
    .{ .name = "pre", .namespace = .xhtml },
    .{ .name = "q", .namespace = .xhtml },
    .{ .name = "rp", .namespace = .xhtml },
    .{ .name = "rt", .namespace = .xhtml },
    .{ .name = "ruby", .namespace = .xhtml },
    .{ .name = "s", .namespace = .xhtml },
    .{ .name = "samp", .namespace = .xhtml },
    .{ .name = "search", .namespace = .xhtml },
    .{ .name = "section", .namespace = .xhtml },
    .{ .name = "small", .namespace = .xhtml },
    .{ .name = "span", .namespace = .xhtml },
    .{ .name = "strong", .namespace = .xhtml },
    .{ .name = "sub", .namespace = .xhtml },
    .{ .name = "sup", .namespace = .xhtml },
    .{ .name = "table", .namespace = .xhtml },
    .{ .name = "tbody", .namespace = .xhtml },
    .{ .name = "td", .namespace = .xhtml, .attributes = &.{ .{ .name = "colspan", .namespace = .none }, .{ .name = "headers", .namespace = .none }, .{ .name = "rowspan", .namespace = .none } } },
    .{ .name = "tfoot", .namespace = .xhtml },
    .{ .name = "th", .namespace = .xhtml, .attributes = &.{ .{ .name = "abbr", .namespace = .none }, .{ .name = "colspan", .namespace = .none }, .{ .name = "headers", .namespace = .none }, .{ .name = "rowspan", .namespace = .none }, .{ .name = "scope", .namespace = .none } } },
    .{ .name = "thead", .namespace = .xhtml },
    .{ .name = "time", .namespace = .xhtml, .attributes = &.{.{ .name = "datetime", .namespace = .none }} },
    .{ .name = "title", .namespace = .xhtml },
    .{ .name = "tr", .namespace = .xhtml },
    .{ .name = "u", .namespace = .xhtml },
    .{ .name = "ul", .namespace = .xhtml },
    .{ .name = "var", .namespace = .xhtml },
    .{ .name = "wbr", .namespace = .xhtml },
    .{ .name = "a", .namespace = .svg, .attributes = &.{ .{ .name = "href", .namespace = .none }, .{ .name = "hreflang", .namespace = .none }, .{ .name = "type", .namespace = .none } } },
    .{ .name = "circle", .namespace = .svg, .attributes = &.{ .{ .name = "cx", .namespace = .none }, .{ .name = "cy", .namespace = .none }, .{ .name = "pathLength", .namespace = .none }, .{ .name = "r", .namespace = .none } } },
    .{ .name = "defs", .namespace = .svg },
    .{ .name = "desc", .namespace = .svg },
    .{ .name = "ellipse", .namespace = .svg, .attributes = &.{ .{ .name = "cx", .namespace = .none }, .{ .name = "cy", .namespace = .none }, .{ .name = "pathLength", .namespace = .none }, .{ .name = "rx", .namespace = .none }, .{ .name = "ry", .namespace = .none } } },
    .{ .name = "foreignObject", .namespace = .svg, .attributes = &.{ .{ .name = "height", .namespace = .none }, .{ .name = "width", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "g", .namespace = .svg },
    .{ .name = "line", .namespace = .svg, .attributes = &.{ .{ .name = "pathLength", .namespace = .none }, .{ .name = "x1", .namespace = .none }, .{ .name = "x2", .namespace = .none }, .{ .name = "y1", .namespace = .none }, .{ .name = "y2", .namespace = .none } } },
    .{ .name = "marker", .namespace = .svg, .attributes = &.{ .{ .name = "markerHeight", .namespace = .none }, .{ .name = "markerUnits", .namespace = .none }, .{ .name = "markerWidth", .namespace = .none }, .{ .name = "orient", .namespace = .none }, .{ .name = "preserveAspectRatio", .namespace = .none }, .{ .name = "refX", .namespace = .none }, .{ .name = "refY", .namespace = .none }, .{ .name = "viewBox", .namespace = .none } } },
    .{ .name = "metadata", .namespace = .svg },
    .{ .name = "path", .namespace = .svg, .attributes = &.{ .{ .name = "d", .namespace = .none }, .{ .name = "pathLength", .namespace = .none } } },
    .{ .name = "polygon", .namespace = .svg, .attributes = &.{ .{ .name = "pathLength", .namespace = .none }, .{ .name = "points", .namespace = .none } } },
    .{ .name = "polyline", .namespace = .svg, .attributes = &.{ .{ .name = "pathLength", .namespace = .none }, .{ .name = "points", .namespace = .none } } },
    .{ .name = "rect", .namespace = .svg, .attributes = &.{ .{ .name = "height", .namespace = .none }, .{ .name = "pathLength", .namespace = .none }, .{ .name = "rx", .namespace = .none }, .{ .name = "ry", .namespace = .none }, .{ .name = "width", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "svg", .namespace = .svg, .attributes = &.{ .{ .name = "height", .namespace = .none }, .{ .name = "preserveAspectRatio", .namespace = .none }, .{ .name = "viewBox", .namespace = .none }, .{ .name = "width", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "text", .namespace = .svg, .attributes = &.{ .{ .name = "dx", .namespace = .none }, .{ .name = "dy", .namespace = .none }, .{ .name = "lengthAdjust", .namespace = .none }, .{ .name = "rotate", .namespace = .none }, .{ .name = "textLength", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "textPath", .namespace = .svg, .attributes = &.{ .{ .name = "lengthAdjust", .namespace = .none }, .{ .name = "method", .namespace = .none }, .{ .name = "path", .namespace = .none }, .{ .name = "side", .namespace = .none }, .{ .name = "spacing", .namespace = .none }, .{ .name = "startOffset", .namespace = .none }, .{ .name = "textLength", .namespace = .none } } },
    .{ .name = "title", .namespace = .svg },
    .{ .name = "tspan", .namespace = .svg, .attributes = &.{ .{ .name = "dx", .namespace = .none }, .{ .name = "dy", .namespace = .none }, .{ .name = "lengthAdjust", .namespace = .none }, .{ .name = "rotate", .namespace = .none }, .{ .name = "textLength", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
};

pub const default_attributes: []const Name = &.{
    .{ .name = "alignment-baseline", .namespace = .none },
    .{ .name = "baseline-shift", .namespace = .none },
    .{ .name = "clip-path", .namespace = .none },
    .{ .name = "clip-rule", .namespace = .none },
    .{ .name = "color", .namespace = .none },
    .{ .name = "color-interpolation", .namespace = .none },
    .{ .name = "cursor", .namespace = .none },
    .{ .name = "dir", .namespace = .none },
    .{ .name = "direction", .namespace = .none },
    .{ .name = "display", .namespace = .none },
    .{ .name = "displaystyle", .namespace = .none },
    .{ .name = "dominant-baseline", .namespace = .none },
    .{ .name = "fill", .namespace = .none },
    .{ .name = "fill-opacity", .namespace = .none },
    .{ .name = "fill-rule", .namespace = .none },
    .{ .name = "font-family", .namespace = .none },
    .{ .name = "font-size", .namespace = .none },
    .{ .name = "font-size-adjust", .namespace = .none },
    .{ .name = "font-stretch", .namespace = .none },
    .{ .name = "font-style", .namespace = .none },
    .{ .name = "font-variant", .namespace = .none },
    .{ .name = "font-weight", .namespace = .none },
    .{ .name = "lang", .namespace = .none },
    .{ .name = "letter-spacing", .namespace = .none },
    .{ .name = "marker-end", .namespace = .none },
    .{ .name = "marker-mid", .namespace = .none },
    .{ .name = "marker-start", .namespace = .none },
    .{ .name = "mathbackground", .namespace = .none },
    .{ .name = "mathcolor", .namespace = .none },
    .{ .name = "mathsize", .namespace = .none },
    .{ .name = "opacity", .namespace = .none },
    .{ .name = "paint-order", .namespace = .none },
    .{ .name = "pointer-events", .namespace = .none },
    .{ .name = "scriptlevel", .namespace = .none },
    .{ .name = "shape-rendering", .namespace = .none },
    .{ .name = "stop-color", .namespace = .none },
    .{ .name = "stop-opacity", .namespace = .none },
    .{ .name = "stroke", .namespace = .none },
    .{ .name = "stroke-dasharray", .namespace = .none },
    .{ .name = "stroke-dashoffset", .namespace = .none },
    .{ .name = "stroke-linecap", .namespace = .none },
    .{ .name = "stroke-linejoin", .namespace = .none },
    .{ .name = "stroke-miterlimit", .namespace = .none },
    .{ .name = "stroke-opacity", .namespace = .none },
    .{ .name = "stroke-width", .namespace = .none },
    .{ .name = "text-anchor", .namespace = .none },
    .{ .name = "text-decoration", .namespace = .none },
    .{ .name = "text-overflow", .namespace = .none },
    .{ .name = "text-rendering", .namespace = .none },
    .{ .name = "title", .namespace = .none },
    .{ .name = "transform", .namespace = .none },
    .{ .name = "transform-origin", .namespace = .none },
    .{ .name = "unicode-bidi", .namespace = .none },
    .{ .name = "vector-effect", .namespace = .none },
    .{ .name = "visibility", .namespace = .none },
    .{ .name = "white-space", .namespace = .none },
    .{ .name = "word-spacing", .namespace = .none },
    .{ .name = "writing-mode", .namespace = .none },
};

// https://html.spec.whatwg.org/#built-in-safe-baseline-configuration
// Every HTML element the spec marks "Sanitization: Unsafe" (base, embed,
// iframe, object, script), plus the obsolete frame and SVG's script and use.
pub const baseline_remove_elements: []const Name = &.{
    .{ .name = "base", .namespace = .xhtml },
    .{ .name = "embed", .namespace = .xhtml },
    .{ .name = "frame", .namespace = .xhtml },
    .{ .name = "iframe", .namespace = .xhtml },
    .{ .name = "object", .namespace = .xhtml },
    .{ .name = "script", .namespace = .xhtml },
    .{ .name = "script", .namespace = .svg },
    .{ .name = "use", .namespace = .svg },
};

// The baseline's own removeAttributes list is empty; `remove unsafe` instead
// walks every "event handler content attribute". We fold lightpanda's own
// handler set into HTML's list so that a handler added to `Handler` -- which is
// what an `on*` content attribute is compiled against -- can never be left
// behind by removeUnsafe().
pub const event_handler_attributes: []const []const u8 = blk: {
    @setEvalBranchQuota(200_000);
    const handlers = std.meta.fieldNames(global_event_handlers.Handler);
    var all: [html_event_handler_attributes.len + handlers.len][]const u8 = undefined;
    for (html_event_handler_attributes, 0..) |name, i| {
        all[i] = name;
    }
    for (handlers, 0..) |name, i| {
        all[html_event_handler_attributes.len + i] = name;
    }
    std.mem.sort([]const u8, &all, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var unique: [all.len][]const u8 = undefined;
    var len: usize = 0;
    for (all) |name| {
        if (len == 0 or std.mem.eql(u8, unique[len - 1], name) == false) {
            unique[len] = name;
            len += 1;
        }
    }
    const final = unique[0..len].*;
    break :blk &final;
};

const html_event_handler_attributes: []const []const u8 = &.{
    "onabort",
    "onactivate",
    "onafterprint",
    "onanimationcancel",
    "onanimationend",
    "onanimationiteration",
    "onanimationstart",
    "onautofill",
    "onauxclick",
    "onbeforecopy",
    "onbeforecut",
    "onbeforefilter",
    "onbeforeinput",
    "onbeforepaste",
    "onbeforeprint",
    "onbeforetoggle",
    "onbeforeunload",
    "onbegin",
    "onblur",
    "oncancel",
    "oncanplay",
    "oncanplaythrough",
    "onchange",
    "onclick",
    "onclose",
    "oncommand",
    "oncontentvisibilityautostatechange",
    "oncontextlost",
    "oncontextmenu",
    "oncontextrestored",
    "oncopy",
    "oncuechange",
    "oncut",
    "ondblclick",
    "ondrag",
    "ondragend",
    "ondragenter",
    "ondragleave",
    "ondragover",
    "ondragstart",
    "ondrop",
    "ondurationchange",
    "onemptied",
    "onend",
    "onended",
    "onerror",
    "onfocus",
    "onfocusin",
    "onfocusout",
    "onformdata",
    "ongotpointercapture",
    "onhashchange",
    "oninput",
    "oninstallresult",
    "oninvalid",
    "onkeydown",
    "onkeypress",
    "onkeyup",
    "onlanguagechange",
    "onload",
    "onloadeddata",
    "onloadedmetadata",
    "onloadstart",
    "onlocation",
    "onlostpointercapture",
    "onmessage",
    "onmessageerror",
    "onmousedown",
    "onmouseenter",
    "onmouseleave",
    "onmousemove",
    "onmouseout",
    "onmouseover",
    "onmouseup",
    "onmousewheel",
    "onmove",
    "onoffline",
    "ononline",
    "onorientationchange",
    "onpagehide",
    "onpageshow",
    "onpaste",
    "onpause",
    "onplay",
    "onplaying",
    "onpointercancel",
    "onpointerdown",
    "onpointerenter",
    "onpointerleave",
    "onpointermove",
    "onpointerout",
    "onpointerover",
    "onpointerrawupdate",
    "onpointerup",
    "onpopstate",
    "onprogress",
    "onpromptaction",
    "onpromptdismiss",
    "onratechange",
    "onrepeat",
    "onreset",
    "onresize",
    "onscroll",
    "onscrollend",
    "onscrollsnapchange",
    "onscrollsnapchanging",
    "onsearch",
    "onsecuritypolicyviolation",
    "onseeked",
    "onseeking",
    "onselect",
    "onselectionchange",
    "onselectstart",
    "onshow",
    "onslotchange",
    "onstalled",
    "onstream",
    "onstorage",
    "onsubmit",
    "onsuspend",
    "ontimeupdate",
    "ontimezonechange",
    "ontoggle",
    "ontouchcancel",
    "ontouchend",
    "ontouchmove",
    "ontouchstart",
    "ontransitionend",
    "onunload",
    "onvalidationstatuschange",
    "onvolumechange",
    "onwaiting",
    "onwebkitanimationend",
    "onwebkitanimationiteration",
    "onwebkitanimationstart",
    "onwebkitfullscreenchange",
    "onwebkitfullscreenerror",
    "onwebkittransitionend",
    "onwheel",
};

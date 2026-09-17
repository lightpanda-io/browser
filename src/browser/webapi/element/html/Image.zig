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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Picture = @import("Picture.zig");
const Source = @import("Source.zig");

const log = lp.log;
const String = lp.String;

const Image = @This();

pub const Proto = HtmlElement;

_generation: u32 = 0,
// Per spec, false only while a fetch is in flight.
_complete: bool = true,
// Hash of the URL the last update selected, so a <picture> mutation that
// leaves the selection unchanged doesn't restart the load.
_selected_hash: u64 = 0,

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try Frame.node_factory.createElementNS(frame.document, .html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Image) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeInterned("src") orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

fn getCurrentSrc(self: *Image, frame: *Frame) ![]const u8 {
    const src = self.selectSource(frame);
    if (src.len == 0) {
        return "";
    }
    return self.asNode().resolveURLReflect(src, frame, .{});
}

fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeInterned("loading") orelse "eager";
}

fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

fn getNaturalWidth(_: *const Image) u32 {
    // this is a valid response under a number of normal conditions, but could
    // be used to detect the nature of Browser.
    return 0;
}

fn getNaturalHeight(_: *const Image) u32 {
    // this is a valid response under a number of normal conditions, but could
    // be used to detect the nature of Browser.
    return 0;
}

fn getComplete(self: *const Image) bool {
    return self._complete;
}

/// Nothing is decoded here, so the image is always ready to insert.
pub fn decode(_: *const Image, frame: *Frame) !js.Promise {
    return frame.js.local.?.resolvePromise(js.Undefined{});
}

/// The one funnel for "this element's selected source may have changed":
/// parser-created images, `img.src = ...`, `setAttribute`/`removeAttribute`
/// of src/srcset and <picture> mutations all land here.
fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger a load event
    // or start fetching a resource.
    if (frame.isGoingAway()) {
        return;
    }

    // A document without a browsing context (DOMParser et al.) loads nothing.
    if (self.asElement().getDocument(frame)._frame == null) {
        return;
    }

    self._generation +%= 1;
    self._complete = true;

    const src = self.selectSource(frame);
    self._selected_hash = std.hash.Wyhash.hash(0, src);
    if (src.len == 0) {
        return;
    }

    // If image loading not desired, we just do fake "load" event.
    if (frame._session.load_resources.image == false) {
        return frame.queueLoad(Factory.protoOf(self));
    }

    Frame.resource_load.image(frame, self, src) catch |err| {
        log.warn(.http, "image fetch", .{ .err = err, .src = src });
        return frame.queueElementEvent(Factory.protoOf(self), .@"error");
    };
}

/// An insertion or <picture> mutation: only restart the load if it changed the
/// selection. A parser-created image has selected nothing until its insertion.
pub fn sourceChanged(self: *Image, frame: *Frame) !void {
    // Yes, we can get collisions, but even if it happens, the impact is low.
    if (std.hash.Wyhash.hash(0, self.selectSource(frame)) == self._selected_hash) {
        return;
    }
    return self.imageAddedCallback(frame);
}

fn selectSource(self: *Image, frame: *Frame) []const u8 {
    const node = self.asNode();
    const viewport_width = frame.page.getViewport().width;

    if (node._parent) |parent| {
        if (parent.is(Picture) != null) {
            var it = parent.childrenIterator();
            while (it.next()) |child| {
                if (child == node) {
                    break;
                }
                const source = child.is(Source) orelse continue;
                const srcset = source.selectableSrcset(frame) orelse continue;
                if (pickCandidate(srcset, "", viewport_width)) |url| {
                    return url;
                }
            }
        }
    }

    const element = self.asElement();
    const src = element.getAttributeInterned("src") orelse "";
    if (element.getAttributeInterned("srcset")) |srcset| {
        if (pickCandidate(srcset, src, viewport_width)) |url| {
            return url;
        }
    }
    return src;
}

// Picks the candidate with the smallest density that is still >= 1, falling
// back to the densest one. `sizes` isn't parsed: a width descriptor is always
// measured against the full viewport width (the 100vw default).
fn pickCandidate(srcset: []const u8, src: []const u8, viewport_width: u32) ?[]const u8 {
    var best: ?Candidate = null;
    var densest: ?Candidate = null;
    var has_1x = false;
    var has_width = false;

    var it: SrcsetIterator = .{ .input = srcset };
    while (it.next()) |candidate| {
        const density = switch (candidate.descriptor) {
            .density => |d| d,
            .width => |w| blk: {
                has_width = true;
                break :blk @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(@max(viewport_width, 1)));
            },
        };
        if (density == 1) {
            has_1x = true;
        }
        if (density >= 1 and (best == null or density < best.?.density)) {
            best = .{ .url = candidate.url, .density = density };
        }
        if (densest == null or density > densest.?.density) {
            densest = .{ .url = candidate.url, .density = density };
        }
    }

    if (src.len > 0 and !has_1x and !has_width) {
        // src is the 1x candidate, nothing in srcset can beat it.
        return src;
    }
    const chosen = best orelse densest orelse return null;
    return chosen.url;
}

const Candidate = struct {
    url: []const u8,
    density: f64,
};

// Candidates with invalid descriptors are skipped.
const SrcsetIterator = struct {
    input: []const u8,
    pos: usize = 0,

    const Parsed = struct {
        url: []const u8,
        descriptor: union(enum) {
            density: f64,
            width: u32,
        },
    };

    fn next(self: *SrcsetIterator) ?Parsed {
        const input = self.input;
        while (true) {
            while (self.pos < input.len and (std.ascii.isWhitespace(input[self.pos]) or input[self.pos] == ',')) {
                self.pos += 1;
            }
            if (self.pos >= input.len) {
                return null;
            }

            const url_start = self.pos;
            while (self.pos < input.len and !std.ascii.isWhitespace(input[self.pos])) {
                self.pos += 1;
            }
            var url = input[url_start..self.pos];

            var descriptors: []const u8 = "";
            if (url[url.len - 1] == ',') {
                url = std.mem.trimEnd(u8, url, ",");
            } else {
                const start = self.pos;
                var in_parens = false;
                while (self.pos < input.len) : (self.pos += 1) {
                    switch (input[self.pos]) {
                        '(' => in_parens = true,
                        ')' => in_parens = false,
                        ',' => if (!in_parens) break,
                        else => {},
                    }
                }
                descriptors = input[start..self.pos];
            }

            if (url.len == 0) {
                continue;
            }
            if (parseDescriptors(descriptors)) |descriptor| {
                return .{ .url = url, .descriptor = descriptor };
            }
        }
    }

    fn parseDescriptors(input: []const u8) ?@FieldType(Parsed, "descriptor") {
        var density: ?f64 = null;
        var width: ?u32 = null;
        var has_height = false;

        var it = std.mem.tokenizeAny(u8, input, " \t\n\r\x0c");
        while (it.next()) |token| {
            const value = token[0 .. token.len - 1];
            switch (token[token.len - 1]) {
                'x' => {
                    if (density != null or width != null or has_height) {
                        return null;
                    }
                    const d = std.fmt.parseFloat(f64, value) catch return null;
                    if (!std.math.isFinite(d) or d < 0 or !isFloatSyntax(value)) {
                        return null;
                    }
                    density = d;
                },
                'w' => {
                    if (density != null or width != null) {
                        return null;
                    }
                    const w = parseNonNegativeInt(value) orelse return null;
                    if (w == 0) {
                        return null;
                    }
                    width = w;
                },
                'h' => {
                    if (density != null or has_height) {
                        return null;
                    }
                    _ = parseNonNegativeInt(value) orelse return null;
                    has_height = true;
                },
                else => return null,
            }
        }

        if (width) |w| {
            return .{ .width = w };
        }
        if (has_height) {
            return null;
        }
        return .{ .density = density orelse 1 };
    }

    // parseInt also accepts a sign and '_' separators.
    fn parseNonNegativeInt(value: []const u8) ?u32 {
        for (value) |c| {
            if (!std.ascii.isDigit(c)) {
                return null;
            }
        }
        return std.fmt.parseInt(u32, value, 10) catch null;
    }

    // parseFloat also accepts "inf", "nan", hex and a leading '+'.
    fn isFloatSyntax(value: []const u8) bool {
        if (value.len == 0 or value[0] == '+') {
            return false;
        }
        for (value) |c| {
            switch (c) {
                '0'...'9', '.', 'e', 'E', '-', '+' => {},
                else => return false,
            }
        }
        return true;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Image.getCurrentSrc, null, .{});
    pub const alt = reflect.string("alt");
    pub const width = reflect.unsignedLong("width", .{});
    pub const height = reflect.unsignedLong("height", .{});
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{ .ce_reactions = true });
    const reflect = Element.Reflect(Image);
    pub const srcset = reflect.string("srcset");
    pub const useMap = reflect.string("usemap");
    pub const isMap = reflect.boolean("ismap");
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const decoding = reflect.enumerated("decoding", &.{ "async", "sync", "auto" }, .{ .missing = "auto" });
    // Obsolete
    pub const name = reflect.string("name");
    pub const lowsrc = reflect.url("lowsrc");
    pub const @"align" = reflect.string("align");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const longDesc = reflect.url("longdesc");
    pub const border = reflect.stringNullToEmpty("border");

    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
    pub const decode = bridge.function(Image.decode, .{});
};

pub const Build = struct {
    // The parser's images wait until they're inserted (sourceChanged), so a
    // <picture> parent's <source> elements take part in the selection.
    pub const parser_created_on_insert = true;

    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!isSourceAttribute(name)) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }

    // Removing the src leaves no request to make, but any in-flight one still
    // has to be invalidated.
    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!isSourceAttribute(name)) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }

    fn isSourceAttribute(name: String) bool {
        return name.eql(comptime .wrap("src")) or name.eql(comptime .wrap("srcset"));
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}

test "WebApi: HTML.Image srcset" {
    try testing.htmlRunner("element/html/image_srcset.html", .{});
}

test "WebApi: HTML.Image fetch" {
    try testing.htmlRunner("element/html/image_fetch.html", .{ .load_resources = .{ .image = true } });
}

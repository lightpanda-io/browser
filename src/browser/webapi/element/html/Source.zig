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
const MediaQuery = @import("../../../css/MediaQuery.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Picture = @import("Picture.zig");

const String = lp.String;

const Source = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Source) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Source) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Source) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Source, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeInterned("src") orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

fn setSrc(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn selectableSrcset(self: *const Source, frame: *Frame) ?[]const u8 {
    const element = self.asConstElement();
    const srcset = element.getAttributeInterned("srcset") orelse return null;
    if (srcset.len == 0) {
        return null;
    }
    if (element.getAttributeInterned("media")) |media| {
        if (std.mem.trim(u8, media, &std.ascii.whitespace).len > 0 and !MediaQuery.matches(media, frame.page.getViewport())) {
            return null;
        }
    }
    if (element.getAttributeInterned("type")) |mime| {
        if (!isSupportedImageType(mime)) {
            return null;
        }
    }
    return srcset;
}

// Nothing is decoded, so claim the formats a mainstream browser does.
fn isSupportedImageType(mime: []const u8) bool {
    const essence = std.mem.trim(u8, mime[0 .. std.mem.indexOfScalar(u8, mime, ';') orelse mime.len], &std.ascii.whitespace);
    if (essence.len == 0) {
        return true;
    }
    const supported = [_][]const u8{
        "image/apng",
        "image/avif",
        "image/bmp",
        "image/gif",
        "image/jpeg",
        "image/jpg",
        "image/png",
        "image/svg+xml",
        "image/vnd.microsoft.icon",
        "image/webp",
        "image/x-icon",
    };
    for (supported) |s| {
        if (std.ascii.eqlIgnoreCase(essence, s)) {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Source);

    pub const Meta = struct {
        pub const name = "HTMLSourceElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Source);

    pub const height = reflect.unsignedLong("height", .{});
    pub const media = reflect.string("media");
    pub const sizes = reflect.string("sizes");
    pub const src = bridge.accessor(Source.getSrc, Source.setSrc, .{ .ce_reactions = true });
    pub const srcset = reflect.string("srcset");
    pub const @"type" = reflect.string("type");
    pub const width = reflect.unsignedLong("width", .{});
};

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!isSelectionAttribute(name)) {
            return;
        }
        return Picture.sourceChanged(element.asNode(), frame);
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!isSelectionAttribute(name)) {
            return;
        }
        return Picture.sourceChanged(element.asNode(), frame);
    }

    fn isSelectionAttribute(name: String) bool {
        return name.eql(comptime .wrap("srcset")) or name.eql(comptime .wrap("media")) or name.eql(comptime .wrap("type"));
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Source" {
    try testing.htmlRunner("element/html/source.html", .{});
}

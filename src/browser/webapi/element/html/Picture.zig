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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Image = @import("Image.zig");
const Source = @import("Source.zig");

const log = lp.log;

const Picture = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Picture) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Picture) *Node {
    return self.asElement().asNode();
}

// A <source> entering the picture. Frame handles an inserted <img> itself.
pub fn childInserted(parent: *Node, child: *Node, frame: *Frame) !void {
    if (parent.is(Picture) == null) {
        return;
    }
    if (child.is(Source) != null) {
        return imagesFrom(child.nextSibling(), frame);
    }
}

// `next_sibling` is the child's sibling from before it was unlinked.
pub fn childRemoved(parent: *Node, child: *Node, next_sibling: ?*Node, frame: *Frame) void {
    if (parent.is(Picture) == null) {
        return;
    }
    const result = if (child.is(Image)) |img|
        img.sourceChanged(frame)
    else if (child.is(Source) != null)
        imagesFrom(next_sibling, frame)
    else
        return;

    result catch |err| {
        log.warn(.frame, "picture child removed", .{ .err = err });
    };
}

// parse.fragment links every child of a parent at once, so the <img> among
// them never saw its <picture> parent.
pub fn childrenInserted(parent: *Node, frame: *Frame) !void {
    if (parent.is(Picture) == null) {
        return;
    }
    return imagesFrom(parent.firstChild(), frame);
}

pub fn sourceChanged(source: *Node, frame: *Frame) !void {
    const parent = source._parent orelse return;
    if (parent.is(Picture) == null) {
        return;
    }
    return imagesFrom(source.nextSibling(), frame);
}

fn imagesFrom(start: ?*Node, frame: *Frame) !void {
    var it = start;
    while (it) |node| : (it = node.nextSibling()) {
        if (node.is(Image)) |img| {
            try img.sourceChanged(frame);
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Picture);

    pub const Meta = struct {
        pub const name = "HTMLPictureElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

const testing = @import("../../../../testing.zig");
test "WebApi: Picture" {
    try testing.htmlRunner("element/html/picture.html", .{});
}

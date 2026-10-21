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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TreeWalker = @import("../../TreeWalker.zig");

const HtmlElement = @import("../Html.zig");

const Label = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Label) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Label) *Node {
    return self.asElement().asNode();
}

pub fn getControl(self: *Label) ?*Element {
    if (self.asElement().getAttributeInterned("for")) |id| {
        // Like Chrome: `for` only resolves in a document or shadow tree, so a
        // detached label has no control by id.
        const node = self.asNode();
        if (!node.isConnected() and !node.isInShadowTree()) {
            return null;
        }
        const el = Frame.getElementByIdFromNode(node, id) orelse return null;
        if (!isLabelable(el)) {
            return null;
        }
        return el;
    }

    var tw = TreeWalker.FullExcludeSelf.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        if (isLabelable(el)) {
            return el;
        }
    }
    return null;
}

fn isLabelable(el: *Element) bool {
    const html = el.is(HtmlElement) orelse return false;
    return switch (html._type) {
        .button, .meter, .output, .progress, .select, .textarea => true,
        .input => html.subtype(HtmlElement.Input)._input_type != .hidden,
        .custom => html.subtype(HtmlElement.Custom).isFormAssociated(),
        else => false,
    };
}

/// First ancestor `<label>` element of `control`, if any.
pub fn findWrappingLabel(control: *Element) ?*Element {
    var current: ?*Node = control.asNode()._parent;
    while (current) |n| : (current = n._parent) {
        const el = n.is(Element) orelse continue;
        if (el.getTag() == .label) return el;
    }
    return null;
}

/// Lazy `for`-attribute → `<label>` index. Built in one tree walk on first
/// lookup; subsequent lookups are O(1). Use when the same document is queried
/// multiple times (e.g. one AX tree walk resolves names for every labellable
/// control).
pub const LabelByForIndex = struct {
    map: std.StringHashMapUnmanaged(*Element) = .empty,
    populated: bool = false,

    pub fn lookup(self: *LabelByForIndex, root: *Node, id: []const u8, allocator: std.mem.Allocator) !?*Element {
        if (!self.populated) {
            var it = TreeWalker.Full.Elements.init(root, .{});
            while (it.next()) |el| {
                if (el.getTag() != .label) continue;
                const for_attr = el.getAttributeInterned("for") orelse continue;
                if (for_attr.len == 0) continue;
                const gop = try self.map.getOrPut(allocator, for_attr);
                if (!gop.found_existing) gop.value_ptr.* = el;
            }
            self.populated = true;
        }
        return self.map.get(id);
    }
};

/// The `<label>` elements whose labeled control is `control`, in tree order.
pub fn getControlLabels(control: *Element, frame: *Frame) !js.Array {
    const local = frame.js.local orelse return error.NotHandled;
    var arr = local.newArray(0);
    var idx: u32 = 0;

    // Like Chrome: a control outside a document or shadow tree has no labels,
    // not even a wrapping one.
    const node = control.asNode();
    if (!node.isConnected() and !node.isInShadowTree()) {
        return arr;
    }

    const root = node.getRootNode(.{});

    // Only an id can pull in a `for` label from elsewhere in the tree, and only
    // if this control is the first element with it. Then walk the whole tree.
    const by_id = if (control.getId()) |id|
        id.len > 0 and Frame.getElementByIdFromNode(root, id) == control
    else
        false;

    if (by_id) {
        var it = TreeWalker.Full.ElementsOf(Label).init(root, .{});
        while (it.next()) |label| {
            if (label.getControl() != control) {
                continue;
            }
            _ = try arr.set(idx, label.asElement(), .{});
            idx += 1;
        }
        return arr;
    }

    // Otherwise only ancestor labels can apply. Count first so nested labels
    // land outermost-first, i.e. in tree order.
    var count: u32 = 0;
    var current: ?*Node = node._parent;
    while (current) |n| : (current = n._parent) {
        const label = n.is(Label) orelse continue;
        if (label.getControl() == control) {
            count += 1;
        }
    }

    idx = count;
    current = node._parent;
    while (current) |n| : (current = n._parent) {
        const label = n.is(Label) orelse continue;
        if (label.getControl() != control) {
            continue;
        }
        idx -= 1;
        _ = try arr.set(idx, label.asElement(), .{});
    }

    return arr;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Label);

    pub const Meta = struct {
        pub const name = "HTMLLabelElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Label);

    pub const htmlFor = reflect.string("for");
    pub const control = bridge.accessor(Label.getControl, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Label" {
    try testing.htmlRunner("element/html/label.html", .{});
    try testing.htmlRunner("element/html/label_click.html", .{});
}

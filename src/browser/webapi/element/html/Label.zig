const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TreeWalker = @import("../../TreeWalker.zig");

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

pub fn getControl(self: *Label, frame: *Frame) ?*Element {
    if (self.asElement().getAttributeSafe(comptime .wrap("for"))) |id| {
        const el = frame.getElementByIdFromNode(self.asElement().asNode(), id) orelse return null;
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
                const for_attr = el.getAttributeSafe(comptime .wrap("for")) orelse continue;
                if (for_attr.len == 0) continue;
                const gop = try self.map.getOrPut(allocator, for_attr);
                if (!gop.found_existing) gop.value_ptr.* = el;
            }
            self.populated = true;
        }
        return self.map.get(id);
    }
};

/// Collects the `<label>` elements associated with a labellable form control.
/// Matches HTMLInputElement.labels (and the equivalent on button/select/etc).
/// Includes every `<label for="id">` reference plus the nearest ancestor
/// `<label>` wrapping the control.
pub fn getControlLabels(control: *Element, frame: *Frame) !js.Array {
    const local = frame.js.local orelse return error.NotHandled;
    var arr = local.newArray(0);
    var idx: u32 = 0;

    if (control.getAttributeSafe(comptime .wrap("id"))) |id_value| {
        if (id_value.len > 0) {
            const doc = control.asNode().ownerDocument(frame);
            const search_root: *Node = if (doc) |d| d.asNode() else control.asNode();
            var it = TreeWalker.Full.Elements.init(search_root, .{});
            while (it.next()) |el| {
                if (el.getTag() != .label) continue;
                const for_attr = el.getAttributeSafe(comptime .wrap("for")) orelse continue;
                if (!std.mem.eql(u8, for_attr, id_value)) continue;
                _ = try arr.set(idx, el, .{});
                idx += 1;
            }
        }
    }

    if (findWrappingLabel(control)) |wrap_label| {
        _ = try arr.set(idx, wrap_label, .{});
        idx += 1;
    }

    return arr;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Label);

    pub const Meta = struct {
        pub const name = "HTMLLabelElement";
        pub const prototype_chain = bridge.prototypeChain();
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

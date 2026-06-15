const js = @import("../../../js/js.zig");
const URL = @import("../../../URL.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Base = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Base) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Base) *Node {
    return self.asElement().asNode();
}

pub fn getTarget(self: *Base) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("target")) orelse "";
}

pub fn setTarget(self: *Base, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("target"), .wrap(value), frame);
}

pub fn getHref(self: *Base, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }
    const owner = element.asConstNode().ownerFrame(frame);
    return URL.resolve(frame.call_arena, owner.url, href, .{});
}

pub fn setHref(self: *Base, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);

    // Per HTML spec, the document's base URL is the href of the FIRST <base>
    // element in tree order that has an href attribute — not necessarily this
    // one. Re-derive from scratch so that setting href on a non-authoritative
    // <base>, or clearing href on the authoritative one, both work correctly.
    const node = element.asNode();
    if (!node.isConnected()) {
        return;
    }

    const owner = node.ownerFrame(frame);
    const first = (try owner.document.querySelector(comptime .wrap("base[href]"), owner)) orelse {
        owner.base_url = null;
        return;
    };
    const href = first.getAttributeSafe(comptime .wrap("href")) orelse {
        owner.base_url = null;
        return;
    };
    if (href.len == 0) {
        owner.base_url = null;
        return;
    }
    owner.base_url = try URL.resolve(owner.arena, owner.url, href, .{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Base);

    pub const Meta = struct {
        pub const name = "HTMLBaseElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const href = bridge.accessor(Base.getHref, Base.setHref, .{ .ce_reactions = true });
    pub const target = bridge.accessor(Base.getTarget, Base.setTarget, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Base" {
    try testing.htmlRunner("element/html/base.html", .{});
}

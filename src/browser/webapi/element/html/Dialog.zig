const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Event = @import("../../Event.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Dialog = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Dialog) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Dialog) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Dialog) *Node {
    return self.asElement().asNode();
}

pub fn getOpen(self: *const Dialog) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

pub fn setOpen(self: *Dialog, open: bool, frame: *Frame) !void {
    if (open) {
        try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    }
}

pub fn getReturnValue(self: *const Dialog) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("returnvalue")) orelse "";
}

pub fn setReturnValue(self: *Dialog, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("returnvalue"), .wrap(value), frame);
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-show
/// If the open attribute is set, return; otherwise set it to the empty string.
/// Focus / inert / top-layer steps are no-ops here — no rendering pipeline.
pub fn show(self: *Dialog, frame: *Frame) !void {
    if (self.getOpen()) return;
    try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-showmodal
/// Throws InvalidStateError if [open] is already set. Sets [open] otherwise.
/// Focus trap, backdrop, and top-layer placement are no-ops — Lightpanda has
/// no layout/compositor; [open] reflecting through to selectors is what
/// downstream consumers rely on.
pub fn showModal(self: *Dialog, frame: *Frame) !void {
    if (self.getOpen()) return error.InvalidStateError;
    try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-close
/// If [open] is unset, return. Otherwise remove [open], optionally update
/// returnValue, and fire a `close` event (non-bubbling, non-cancelable).
pub fn close(self: *Dialog, return_value: ?[]const u8, frame: *Frame) !void {
    if (!self.getOpen()) return;
    try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    if (return_value) |v| {
        try self.asElement().setAttributeSafe(comptime .wrap("returnvalue"), .wrap(v), frame);
    }
    const event = try Event.init("close", .{ .bubbles = false, .cancelable = false }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Dialog);

    pub const Meta = struct {
        pub const name = "HTMLDialogElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const open = bridge.accessor(Dialog.getOpen, Dialog.setOpen, .{ .ce_reactions = true });
    pub const returnValue = bridge.accessor(Dialog.getReturnValue, Dialog.setReturnValue, .{});

    pub const show = bridge.function(Dialog.show, .{});
    pub const showModal = bridge.function(Dialog.showModal, .{ .dom_exception = true });
    pub const close = bridge.function(Dialog.close, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Dialog" {
    try testing.htmlRunner("element/html/dialog.html", .{});
}

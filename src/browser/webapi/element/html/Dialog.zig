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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Event = @import("../../Event.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const Dialog = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Dialog) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Dialog) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Dialog) *Node {
    return self.asElement().asNode();
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
fn showModal(self: *Dialog, frame: *Frame) !void {
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
    const event = try Event.init("close", .{ .bubbles = false, .cancelable = false }, frame.page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub fn getOpen(self: *const Dialog) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Dialog);

    pub const Meta = struct {
        pub const name = "HTMLDialogElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Dialog);

    pub const open = reflect.boolean("open");
    pub const returnValue = reflect.string("returnvalue");

    pub const show = bridge.function(Dialog.show, .{});
    pub const showModal = bridge.function(Dialog.showModal, .{});
    pub const close = bridge.function(Dialog.close, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Dialog" {
    try testing.htmlRunner("element/html/dialog.html", .{});
}

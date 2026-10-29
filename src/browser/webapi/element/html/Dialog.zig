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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Event = @import("../../Event.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const popover = @import("../popover.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;
const Dialog = @This();

pub const Proto = HtmlElement;

// internal state, not reflected to an attribute
_return_value: []const u8 = "",
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
/// Focus trap, backdrop, and top-layer placement are no-ops — Lightpanda has
/// no layout/compositor; [open] reflecting through to selectors is what
/// downstream consumers rely on.
fn showModal(self: *Dialog, frame: *Frame) !void {
    const node = self.asNode();
    // The dialog's own document, which isn't the caller's for a cross-frame call.
    const modal_dialogs = &node.getDocument(frame)._modal_dialogs;
    if (self.getOpen()) {
        if (std.mem.findScalar(*Dialog, modal_dialogs.items, self) != null) {
            // no-op if already opend
            return;
        }
        // error if opened non-modally
        return error.InvalidStateError;
    }
    if (node.isConnected() == false or popover.isOpen(self.asElement(), frame)) {
        // invalid if disconnected or showing a popover
        return error.InvalidStateError;
    }
    try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
    try modal_dialogs.append(frame.page_arena, self);
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#close-requests
/// Escape's close request, handled by the topmost modal dialog's close
/// watcher: fire `cancel` and, unless a listener cancels it, close the dialog
/// without changing returnValue. Chrome makes `cancel` cancelable only with
/// history-action user activation; that isn't tracked, so it always is.
pub fn requestCloseTopModal(frame: *Frame) !void {
    const stack = frame.document._modal_dialogs.items;
    if (stack.len == 0) return;
    const dialog = stack[stack.len - 1];

    const event = try Event.init("cancel", .{ .bubbles = false, .cancelable = true }, frame.page);
    if (try frame._event_manager.dispatchCancelable(dialog.asElement().asEventTarget(), event)) {
        return;
    }
    // A cancel listener may already have closed it; close() is then a no-op.
    try dialog.close(null, frame);
}

fn removeModal(element: *Element, frame: *Frame) void {
    const dialog = element.is(Dialog) orelse return;
    const list = &element.asNode().getDocument(frame)._modal_dialogs;
    for (list.items, 0..) |item, i| {
        if (item == dialog) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-close
/// If [open] is unset, return. Otherwise remove [open], optionally update
/// returnValue, and queue a `close` event (non-bubbling, non-cancelable).
pub fn close(self: *Dialog, return_value: ?[]const u8, frame: *Frame) !void {
    if (!self.getOpen()) return;
    try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    if (return_value) |v| {
        try self.setReturnValue(v, frame);
    }
    try frame.queueElementEvent(Factory.protoOf(self), .close);
}

pub fn getReturnValue(self: *const Dialog) []const u8 {
    return self._return_value;
}

pub fn setReturnValue(self: *Dialog, value: []const u8, frame: *Frame) !void {
    if (std.mem.eql(u8, self._return_value, value)) {
        return;
    }
    self._return_value = try frame.page_arena.dupe(u8, value);
}

pub fn getOpen(self: *const Dialog) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

// The dialog cleanup steps: a dialog that loses [open] (close() included) or
// leaves the document stops being modal.
pub const Build = struct {
    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (name.eql(comptime .wrap("open"))) {
            removeModal(element, frame);
        }
    }

    pub fn disconnected(element: *Element, frame: *Frame) !void {
        removeModal(element, frame);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Dialog);

    pub const Meta = struct {
        pub const name = "HTMLDialogElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Dialog);

    pub const open = reflect.boolean("open");
    pub const returnValue = bridge.accessor(Dialog.getReturnValue, Dialog.setReturnValue, .{});

    pub const show = bridge.function(Dialog.show, .{});
    pub const showModal = bridge.function(Dialog.showModal, .{});
    pub const close = bridge.function(Dialog.close, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Dialog" {
    try testing.htmlRunner("element/html/dialog.html", .{});
}

test "WebApi: HTML.Dialog close request" {
    const page = try testing.pageTest("element/html/dialog_close_request.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // Each step runs its script, presses a trusted Escape when `press` is set,
    // runs the queued events, then compares the page's state() summary.
    const steps = [_]struct { []const u8, bool, []const u8 }{
        // The modal dialog closes; returnValue is left unchanged.
        .{ "reset(); A.returnValue = 'keep'; A.showModal()", true, "a:false b:false rv:keep| log:cancel@a,close@a!" },
        // Only the topmost modal closes, then the one below it.
        .{ "reset(); A.showModal(); B.showModal()", true, "a:true b:false rv:| log:cancel@b,close@b!" },
        .{ "", true, "a:false b:false rv:| log:cancel@b,close@b!,cancel@a,close@a!" },
        // Cancelling `cancel` keeps the dialog open.
        .{ "reset(); A.showModal(); preventCancel = true", true, "a:true b:false rv:| log:cancel@a" },
        // Cancelling the keydown stops the close request entirely.
        .{ "reset(); A.showModal(); preventKeydown = true", true, "a:true b:false rv:| log:" },
        // A dialog opened with show() has no close watcher.
        .{ "reset(); A.show()", true, "a:true b:false rv:| log:" },
        // An untrusted keydown has no default action.
        .{ "reset(); A.showModal(); document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))", false, "a:true b:false rv:| log:" },
        // Removing [open] or the dialog itself takes it out of the stack.
        .{ "reset(); A.showModal(); B.showModal(); B.removeAttribute('open')", true, "a:false b:false rv:| log:cancel@a,close@a!" },
        .{ "reset(); A.showModal(); B.showModal(); B.remove()", true, "a:false b:true rv:| log:cancel@a,close@a!" },
        // With no modal dialog, Escape does nothing.
        .{ "reset()", true, "a:false b:false rv:| log:" },
    };
    for (steps) |step| {
        const script, const press, const expected = step;
        _ = try ls.local.compileAndRun(script, null);
        if (press) {
            try pressEscape(frame);
        }
        // close is a queued event
        try frame.js.scheduler.run();
        const actual = try (try ls.local.compileAndRun("state()", null)).toStringSliceWithAlloc(testing.arena_allocator);
        try testing.expectString(expected, actual);
    }

    // A dialog shown from another frame is modal in its own document, so only
    // an Escape pressed in that document closes it.
    const child = frame.child_frames.items[0];
    _ = try ls.local.compileAndRun("C().showModal()", null);
    try pressEscape(frame);
    try testing.expectEqual(true, (try ls.local.compileAndRun("C().open", null)).toBool());
    try pressEscape(child);
    try testing.expectEqual(false, (try ls.local.compileAndRun("C().open", null)).toBool());
}

fn pressEscape(frame: *Frame) !void {
    const keyboard = @import("../../../frame/keyboard.zig");
    const escape = keyboard.named("Escape");
    try keyboard.dispatch(frame, null, .down, &escape, &.{});
    try keyboard.dispatch(frame, null, .up, &escape, &.{});
}

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

// We don't have a layout/rendering engine, so this only models the DOM state:
// a popover is "showing" iff it's a member of its document's `_open_popovers` list

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const ToggleEvent = @import("../event/ToggleEvent.zig");

const HtmlElement = @import("Html.zig");

const log = lp.log;
const String = lp.String;

pub fn getState(el: *Element) ?State {
    return State.parse(el.getAttributeSafe(comptime .wrap("popover")));
}
pub fn getInvokerAction(el: *Element) Action {
    return Action.parse(el.getAttributeSafe(.wrap("popovertargetaction")));
}

pub fn isOpen(el: *Element, frame: *Frame) bool {
    for (frame.document._open_popovers.items) |p| {
        if (p == el) {
            return true;
        }
    }
    return false;
}

pub fn show(el: *Element, frame: *Frame) !void {
    const original = getState(el) orelse return error.NotSupported;

    if (el.asNode().isConnected() == false) {
        return error.InvalidStateError;
    }

    if (isOpen(el, frame)) {
        // already showing: no-op (must not throw)
        return;
    }

    if (try fireToggle(el, comptime .wrap("beforetoggle"), "closed", "open", true, frame)) {
        // was canceled
        return;
    }

    if (hasChanged(el, frame, original)) {
        return error.InvalidStateError;
    }

    if (original != .manual) {
        // showing an auto/hint popover dismisses other auto/hint popovers
        try hideUnrelatedAutos(el, frame);
        if (hasChanged(el, frame, original)) {
            return error.InvalidStateError;
        }
    }

    try frame.document._open_popovers.append(frame.arena, el);
    frame.domChanged();
    _ = try fireToggle(el, comptime .wrap("toggle"), "closed", "open", false, frame);
}

pub fn hide(el: *Element, frame: *Frame) !void {
    if (getState(el) == null) {
        return error.NotSupported;
    }
    if (isOpen(el, frame) == false) {
        // already hidden
        return;
    }
    try hideThroughStack(el, frame);
}

pub fn toggle(el: *Element, force: ?bool, frame: *Frame) !bool {
    if (getState(el) == null) {
        return error.NotSupported;
    }

    const open = isOpen(el, frame);
    if (force) |f| {
        if (f and !open) try show(el, frame);
        if (!f and open) try hide(el, frame);
    } else if (open) {
        try hide(el, frame);
    } else {
        try show(el, frame);
    }
    return isOpen(el, frame);
}

// Hide every popover shown above `el` in the stack, then `el` itself, firing
// events top-down so nested popovers close before their ancestors.
fn hideThroughStack(el: *Element, frame: *Frame) !void {
    const open = &frame.document._open_popovers;
    while (isOpen(el, frame)) {
        const top = open.items[open.items.len - 1];
        try hideOne(top, frame);

        if (top == el) {
            break;
        }
    }
}

fn hideUnrelatedAutos(el: *Element, frame: *Frame) !void {
    // This is a rescan on each round because the event we fire can result in the
    // list being mutated
    const node = el.asNode();
    while (true) {
        const items = frame.document._open_popovers.items;
        var target: ?*Element = null;
        var i: usize = items.len;
        while (i > 0) {
            i -= 1;
            const p = items[i];
            if (p == el) {
                continue;
            }
            const ps = getState(p) orelse continue;
            if (ps == .manual) {
                continue;
            }
            if (p.asNode().contains(node)) {
                continue; // ancestor: keep open
            }
            target = p;
            break;
        }
        // nothing left to dismiss
        const t = target orelse break;
        try hideOne(t, frame);
    }
}

fn hideOne(el: *Element, frame: *Frame) !void {
    removeFromOpen(el, frame);
    frame.domChanged();
    _ = try fireToggle(el, comptime .wrap("beforetoggle"), "open", "closed", false, frame);
    _ = try fireToggle(el, comptime .wrap("toggle"), "open", "closed", false, frame);
}

// Called when an element's `popover` content attribute is set, changed, or
// removed. A showing popover must be hidden if its type changes.
pub fn attributeChanged(el: *Element, old_value: ?[]const u8, new_value: ?[]const u8, frame: *Frame) void {
    if (isOpen(el, frame) == false) {
        return;
    }

    if (State.parse(old_value) == State.parse(new_value)) {
        return;
    }

    hideThroughStack(el, frame) catch |err| {
        log.err(.bug, "popover.forceClose", .{ .err = err });
    };
}

pub fn removeFromOpen(el: *Element, frame: *Frame) void {
    const list = &frame.document._open_popovers;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] == el) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// The popover targeted by an invoker (a <button>, or input button), resolving
// the explicitly IDL-set element or the `popovertarget` IDREF content attribute.
pub fn invokerTarget(invoker: *Node, explicit: ?*Element, frame: *Frame) ?*Element {
    if (explicit) |target| {
        if (target.asNode().getRootNode(null) == invoker.getRootNode(null)) {
            // The invoker and target must share the same root
            return target;
        }
        return null;
    }
    const el = invoker.is(Element) orelse return null;
    const id = el.getAttributeSafe(.wrap("popovertarget")) orelse return null;
    return frame.document.getElementById(id, frame);
}

pub fn runInvokerActivation(invoker: *HtmlElement, explicit: ?*Element, frame: *Frame) !void {
    switch (invoker._type) {
        .button => {},
        .input => |input| switch (input._input_type) {
            .button, .submit, .reset, .image => {},
            else => return, // not an invoker
        },
        else => return, // not an invoker
    }
    const invoker_elem = invoker.asElement();
    const invoker_node = invoker_elem.asNode();

    const target = invokerTarget(invoker_node, explicit, frame) orelse return;

    if (getState(target) == null) {
        return;
    }

    const open = isOpen(target, frame);
    const result: anyerror!void = switch (getInvokerAction(invoker_elem)) {
        .toggle => if (open) hide(target, frame) else show(target, frame),
        .show => if (open) {} else show(target, frame),
        .hide => if (open) hide(target, frame) else {},
    };

    // swallow activation errors, they don't propagate
    result catch |err| switch (err) {
        error.InvalidStateError, error.NotSupported => {},
        else => return err,
    };
}

fn fireToggle(
    el: *Element,
    typ: String,
    old_state: []const u8,
    new_state: []const u8,
    cancelable: bool,
    frame: *Frame,
) !bool {
    const event = (try ToggleEvent.initTrusted(typ, .{
        .cancelable = cancelable,
        .oldState = old_state,
        .newState = new_state,
    }, frame)).asEvent();

    // Keep the event alive while dispatching so we can read _prevent_default.
    event.acquireRef();
    defer _ = event.releaseRef(frame._page);

    try frame._event_manager.dispatch(el.asEventTarget(), event);
    return event._prevent_default;
}

fn hasChanged(el: *Element, frame: *Frame, original: State) bool {
    const now = getState(el) orelse return true;
    if (now != original) {
        return true;
    }
    if (el.asNode().isConnected() == false) {
        return true;
    }
    if (isOpen(el, frame)) {
        return true;
    }
    return false;
}

const State = enum {
    auto,
    hint,
    manual,

    fn parse(value_: ?[]const u8) ?State {
        const value = value_ orelse return null;
        if (value.len == 0) {
            return .auto;
        }

        if (std.ascii.eqlIgnoreCase(value, "auto")) {
            return .auto;
        }
        if (std.ascii.eqlIgnoreCase(value, "manual")) {
            return .manual;
        }
        if (std.ascii.eqlIgnoreCase(value, "hint")) {
            return .hint;
        }

        // default for an invalid value
        return .manual;
    }
};

const Action = enum {
    toggle,
    show,
    hide,

    fn parse(value_: ?[]const u8) Action {
        const value = value_ orelse return .toggle;

        if (std.ascii.eqlIgnoreCase(value, "show")) {
            return .show;
        }

        if (std.ascii.eqlIgnoreCase(value, "hide")) {
            return .hide;
        }

        // missing/invalid value default
        return .toggle;
    }
};

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
const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const Node = @import("Node.zig");
const DocumentFragment = @import("DocumentFragment.zig");
const Element = @import("Element.zig");

const ShadowRoot = @This();

pub const Mode = enum {
    open,
    closed,
};

pub const SlotAssignment = enum {
    named,
    manual,
};

pub const AttachOptions = struct {
    mode: Mode,
    delegates_focus: bool = false,
    slot_assignment: SlotAssignment = .named,
    clonable: bool = false,
    serializable: bool = false,
    declarative: bool = false,
};

_proto: *DocumentFragment,
_mode: Mode,
_host: *Element,
_delegates_focus: bool,
_slot_assignment: SlotAssignment,
_clonable: bool,
_serializable: bool,
_declarative: bool,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .{},
_removed_ids: std.StringHashMapUnmanaged(void) = .{},
_adopted_style_sheets: ?js.Object.Global = null,

pub fn init(host: *Element, opts: AttachOptions, frame: *Frame) !*ShadowRoot {
    return frame._factory.documentFragment(ShadowRoot{
        ._proto = undefined,
        ._mode = opts.mode,
        ._host = host,
        ._delegates_focus = opts.delegates_focus,
        ._slot_assignment = opts.slot_assignment,
        ._clonable = opts.clonable,
        ._serializable = opts.serializable,
        ._declarative = opts.declarative,
    });
}

pub fn asDocumentFragment(self: *ShadowRoot) *DocumentFragment {
    return self._proto;
}

pub fn asNode(self: *ShadowRoot) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *ShadowRoot) *@import("EventTarget.zig") {
    return self.asNode().asEventTarget();
}

pub fn getMode(self: *const ShadowRoot) []const u8 {
    return @tagName(self._mode);
}

pub fn getHost(self: *const ShadowRoot) *Element {
    return self._host;
}

pub fn getDelegatesFocus(self: *const ShadowRoot) bool {
    return self._delegates_focus;
}

pub fn getSlotAssignment(self: *const ShadowRoot) []const u8 {
    return @tagName(self._slot_assignment);
}

pub fn getClonable(self: *const ShadowRoot) bool {
    return self._clonable;
}

pub fn getSerializable(self: *const ShadowRoot) bool {
    return self._serializable;
}

pub fn setHTMLUnsafe(self: *ShadowRoot, html: []const u8, frame: *Frame) !void {
    return self.asDocumentFragment().setHTMLUnsafe(html, frame);
}

pub fn getOnSlotChange(self: *ShadowRoot, frame: *Frame) ?js.Function.Global {
    return frame._event_target_attr_listeners.get(.{ .target = self.asEventTarget(), .handler = .onslotchange });
}

pub fn setOnSlotChange(self: *ShadowRoot, callback: ?js.Function.Global, frame: *Frame) !void {
    if (callback) |cb| {
        try frame._event_target_attr_listeners.put(frame.arena, .{ .target = self.asEventTarget(), .handler = .onslotchange }, cb);
    } else {
        _ = frame._event_target_attr_listeners.remove(.{ .target = self.asEventTarget(), .handler = .onslotchange });
    }
}

pub fn getElementById(self: *ShadowRoot, id: []const u8, frame: *Frame) ?*Element {
    if (id.len == 0) {
        return null;
    }

    // Fast path: ID is in the map
    if (self._elements_by_id.get(id)) |element| {
        return element;
    }

    // Slow path: ID was removed but might have duplicates
    if (self._removed_ids.remove(id)) {
        // Do a tree walk to find another element with this ID
        var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
        while (tw.next()) |el| {
            const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
            if (std.mem.eql(u8, element_id, id)) {
                // we ignore this error to keep getElementById easy to call
                // if it really failed, then we're out of memory and nothing's
                // going to work like it should anyways.
                const owned_id = frame.dupeString(id) catch return null;
                self._elements_by_id.put(frame.arena, owned_id, el) catch return null;
                return el;
            }
        }
    }

    return null;
}

pub fn getAdoptedStyleSheets(self: *ShadowRoot, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

pub fn setAdoptedStyleSheets(self: *ShadowRoot, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ShadowRoot);

    pub const Meta = struct {
        pub const name = "ShadowRoot";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const mode = bridge.accessor(ShadowRoot.getMode, null, .{});
    pub const host = bridge.accessor(ShadowRoot.getHost, null, .{});
    pub const delegatesFocus = bridge.accessor(ShadowRoot.getDelegatesFocus, null, .{});
    pub const slotAssignment = bridge.accessor(ShadowRoot.getSlotAssignment, null, .{});
    pub const clonable = bridge.accessor(ShadowRoot.getClonable, null, .{});
    pub const serializable = bridge.accessor(ShadowRoot.getSerializable, null, .{});
    pub const getElementById = bridge.function(_getElementById, .{});
    fn _getElementById(self: *ShadowRoot, value_: ?js.Value, frame: *Frame) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null", frame);
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined", frame);
        }
        return self.getElementById(try value.toZig([]const u8), frame);
    }
    pub const adoptedStyleSheets = bridge.accessor(ShadowRoot.getAdoptedStyleSheets, ShadowRoot.setAdoptedStyleSheets, .{});
    pub const setHTMLUnsafe = bridge.function(ShadowRoot.setHTMLUnsafe, .{ .dom_exception = true, .ce_reactions = true });
    pub const onslotchange = bridge.accessor(ShadowRoot.getOnSlotChange, ShadowRoot.setOnSlotChange, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ShadowRoot" {
    try testing.htmlRunner("shadowroot", .{});
}

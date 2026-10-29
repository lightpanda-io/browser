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

const dump = @import("../dump.zig");
const EventTarget = @import("EventTarget.zig");
const Frame = @import("../Frame.zig");
const IdMap = @import("../IdMap.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Sanitizer = @import("Sanitizer.zig");
const DocumentFragment = @import("DocumentFragment.zig");

const ShadowRoot = @This();

pub const Proto = DocumentFragment;

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
_available_to_internals: bool = false,
_ids: IdMap = .{},
_adopted_style_sheets: ?js.Object.Global = null,

pub fn init(host: *Element, opts: AttachOptions, frame: *Frame) !*ShadowRoot {
    return frame._factory.documentFragment(host.getDocument(frame), ShadowRoot{
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

fn getDelegatesFocus(self: *const ShadowRoot) bool {
    return self._delegates_focus;
}

fn getSlotAssignment(self: *const ShadowRoot) []const u8 {
    return @tagName(self._slot_assignment);
}

fn getClonable(self: *const ShadowRoot) bool {
    return self._clonable;
}

fn getSerializable(self: *const ShadowRoot) bool {
    return self._serializable;
}

pub fn setHTML(self: *ShadowRoot, html: []const u8, options: ?Sanitizer.Options, frame: *Frame) !void {
    return Sanitizer.setAndFilterHTML(self.asNode(), self._host, html, options, true, frame);
}

pub fn setHTMLUnsafe(self: *ShadowRoot, html: []const u8, options: ?Sanitizer.Options, frame: *Frame) !void {
    return Sanitizer.setAndFilterHTML(self.asNode(), self._host, html, options, false, frame);
}

pub fn getHTML(self: *ShadowRoot, opts: dump.Opts.Shadow.Declarative, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.getHTML(self.asNode(), opts, writer, frame);
}

pub fn getActiveElement(self: *ShadowRoot, frame: *Frame) ?*Element {
    const root = self.asNode();
    const document = root.ownerDocument(frame) orelse frame.document;

    // This is answering two questions:
    // 1 - is the active element contained by me (if not, return null)
    // 2 - if it is, is there 1+ other shadowroot between us
    //     a - if there is, return the nearest (to self) shadowroot's host
    //     b - if there isn't, return the active element
    var candidate = document._active_element orelse return null;
    while (candidate.asNode().getRootNode(.{}) != root) {
        const shadow = candidate.asNode().containingShadowRoot() orelse return null;
        candidate = shadow._host;
    }
    return candidate;
}

pub fn getElementById(self: *ShadowRoot, id: []const u8) ?*Element {
    if (id.len == 0) {
        return null;
    }
    return self._ids.get(self.asNode(), id);
}

fn getAdoptedStyleSheets(self: *ShadowRoot, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

fn setAdoptedStyleSheets(self: *ShadowRoot, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

fn elementFromPoint(self: *ShadowRoot, x: f64, y: f64, frame: *Frame) !?*Element {
    const node = self.asNode();
    return node.getDocument(frame).elementFromPointIn(node, x, y, frame);
}

fn elementsFromPoint(self: *ShadowRoot, x: f64, y: f64, frame: *Frame) ![]const *Element {
    const node = self.asNode();
    return node.getDocument(frame).elementsFromPointIn(node, x, y, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ShadowRoot);

    pub const Meta = struct {
        pub const name = "ShadowRoot";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const activeElement = bridge.accessor(ShadowRoot.getActiveElement, null, .{});
    pub const mode = bridge.accessor(ShadowRoot.getMode, null, .{});
    pub const host = bridge.accessor(ShadowRoot.getHost, null, .{});
    pub const delegatesFocus = bridge.accessor(ShadowRoot.getDelegatesFocus, null, .{});
    pub const slotAssignment = bridge.accessor(ShadowRoot.getSlotAssignment, null, .{});
    pub const clonable = bridge.accessor(ShadowRoot.getClonable, null, .{});
    pub const serializable = bridge.accessor(ShadowRoot.getSerializable, null, .{});
    pub const getElementById = bridge.function(_getElementById, .{});
    fn _getElementById(self: *ShadowRoot, value_: ?js.Value) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null");
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined");
        }
        return self.getElementById(try value.toZig([]const u8));
    }
    pub const adoptedStyleSheets = bridge.accessor(ShadowRoot.getAdoptedStyleSheets, ShadowRoot.setAdoptedStyleSheets, .{});
    pub const elementFromPoint = bridge.function(ShadowRoot.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(ShadowRoot.elementsFromPoint, .{});
    pub const setHTML = bridge.function(ShadowRoot.setHTML, .{ .ce_reactions = true });
    pub const setHTMLUnsafe = bridge.function(ShadowRoot.setHTMLUnsafe, .{ .ce_reactions = true });
    pub const getHTML = bridge.function(_getHTML, .{});
    const GetHTMLOpts = struct {
        serializableShadowRoots: bool = false,
        shadowRoots: []const *ShadowRoot = &.{},
    };
    fn _getHTML(self: *ShadowRoot, opts_: ?GetHTMLOpts, frame: *Frame) ![]const u8 {
        const opts = opts_ orelse GetHTMLOpts{};
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getHTML(.{
            .shadow_roots = opts.shadowRoots,
            .serializable_shadow_roots = opts.serializableShadowRoots,
        }, &buf.writer, frame);
        return buf.written();
    }
    pub const onslotchange = EventTarget.handlerAccessor(ShadowRoot, "slotchange");
};

const testing = @import("../../testing.zig");
test "WebApi: ShadowRoot" {
    try testing.htmlRunner("shadowroot", .{});
}

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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;
const String = lp.String;

const Style = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_sheet: ?*CSSStyleSheet = null,

pub fn asHtml(self: *Style) *HtmlElement {
    return Factory.protoOf(self);
}
pub fn asElement(self: *Style) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Style) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Style) *Node {
    return self.asElement().asNode();
}

// Attribute-backed properties

const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");
fn getSheet(self: *Style, frame: *Frame) !?*CSSStyleSheet {
    // Per spec, sheet is null for disconnected elements or non-CSS types.
    // Valid types: absent (defaults to "text/css"), empty string, or
    // case-insensitive match for "text/css".
    if (!self.asNode().isConnected()) {
        self._sheet = null;
        return null;
    }
    const t = self.getType();
    if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) {
        self._sheet = null;
        return null;
    }

    if (self._sheet) |sheet| return sheet;
    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), frame);
    self._sheet = sheet;

    const owner = self.asNode().ownerDocument(frame) orelse frame.document;
    const sheets = try owner.getStyleSheets(frame);
    try sheets.add(sheet, frame);

    return sheet;
}

pub fn styleAddedCallback(self: *Style, frame: *Frame) !void {
    // Force stylesheet initialization so rules are parsed immediately
    if (self.getSheet(frame) catch null) |_| {
        // Notify StyleManager about the new stylesheet
        frame._style_manager.sheetModified();
    }

    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    try frame.queueLoad(self.asHtml());
}

// The disabled IDL attribute has no content attribute: it reads and writes
// the associated sheet's disabled flag, and does nothing without a sheet.
fn getDisabled(self: *Style, frame: *Frame) !bool {
    const sheet = try self.getSheet(frame) orelse return false;
    return sheet._disabled;
}

fn setDisabled(self: *Style, disabled: bool, frame: *Frame) !void {
    const sheet = try self.getSheet(frame) orelse return;
    sheet.setDisabled(disabled, frame);
}

fn getBlocking(self: *Style, frame: *Frame) !*DOMTokenList {
    return self.asElement().getTokenList(.blocking, frame);
}

fn setBlocking(self: *Style, value: String, frame: *Frame) !void {
    const list = try self.getBlocking(frame);
    try list.setValue(value, frame);
}

pub fn getType(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeInterned("type") orelse "";
}

// The element's text changed. Spec says we should create a new sheet. For now
// we keep the existing one..avoids over-allocation on consecutive writes.
pub fn childrenChanged(self: *Style, frame: *Frame) void {
    const node = self.asNode();
    if (node.isConnected() == false) {
        return;
    }
    if (self._sheet) |sheet| {
        sheet._css_rules = null;
    }
    const owner = node.ownerFrame(frame) orelse return;
    owner._style_manager.sheetModified();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Style);

    pub const Meta = struct {
        pub const name = "HTMLStyleElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Style);
    pub const nonce = reflect.string("nonce");

    pub const blocking = bridge.accessor(Style.getBlocking, Style.setBlocking, .{ .ce_reactions = true });
    pub const media = reflect.string("media");
    pub const @"type" = reflect.string("type");
    pub const disabled = bridge.accessor(Style.getDisabled, Style.setDisabled, .{});
    pub const sheet = bridge.accessor(Style.getSheet, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Style" {
    try testing.htmlRunner("element/html/style.html", .{});
}

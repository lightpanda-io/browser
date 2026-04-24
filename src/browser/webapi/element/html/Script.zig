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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Script = @This();

_proto: *HtmlElement,
_src: []const u8 = "",
_executed: bool = false,
// dynamic scripts are forced to be async by default
_force_async: bool = true,

pub fn asElement(self: *Script) *Element {
    return self._proto._proto;
}

pub fn asConstElement(self: *const Script) *const Element {
    return self._proto._proto;
}

pub fn asNode(self: *Script) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *Script, frame: *Frame) ![]const u8 {
    if (self._src.len == 0) return "";
    return self.asNode().resolveURL(self._src, frame, .{});
}

pub fn setSrc(self: *Script, src: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("src"), .wrap(src), frame);
    self._src = element.getAttributeSafe(comptime .wrap("src")) orelse unreachable;
    if (element.asNode().isConnected()) {
        try frame.scriptAddedCallback(false, self);
    }
}

pub fn getType(self: *const Script) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "";
}

pub fn setType(self: *Script, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), frame);
}

pub fn getNonce(self: *const Script) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("nonce")) orelse "";
}

pub fn setNonce(self: *Script, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("nonce"), .wrap(value), frame);
}

pub fn getCharset(self: *const Script) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("charset")) orelse "";
}

pub fn setCharset(self: *Script, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("charset"), .wrap(value), frame);
}

pub fn getAsync(self: *const Script) bool {
    return self._force_async or self.asConstElement().getAttributeSafe(comptime .wrap("async")) != null;
}

pub fn setAsync(self: *Script, value: bool, frame: *Frame) !void {
    self._force_async = false;
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("async"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("async"), frame);
    }
}

pub fn getDefer(self: *const Script) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("defer")) != null;
}

pub fn setDefer(self: *Script, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("defer"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("defer"), frame);
    }
}

pub fn getNoModule(self: *const Script) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("nomodule")) != null;
}

pub fn setInnerText(self: *Script, text: []const u8, frame: *Frame) !void {
    try self.asNode().setTextContent(text, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Script);

    pub const Meta = struct {
        pub const name = "HTMLScriptElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const src = bridge.accessor(Script.getSrc, Script.setSrc, .{});
    pub const @"defer" = bridge.accessor(Script.getDefer, Script.setDefer, .{});
    pub const async = bridge.accessor(Script.getAsync, Script.setAsync, .{});
    pub const @"type" = bridge.accessor(Script.getType, Script.setType, .{});
    pub const nonce = bridge.accessor(Script.getNonce, Script.setNonce, .{});
    pub const charset = bridge.accessor(Script.getCharset, Script.setCharset, .{});
    pub const noModule = bridge.accessor(Script.getNoModule, null, .{});
    pub const innerText = bridge.accessor(_innerText, Script.setInnerText, .{});
    fn _innerText(self: *Script, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.call_arena);
        try self.asNode().getTextContent(&buf.writer);
        return buf.written();
    }
    pub const text = bridge.accessor(_text, Script.setInnerText, .{});
    fn _text(self: *Script, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.call_arena);
        try self.asNode().getChildTextContent(&buf.writer);
        return buf.written();
    }
};

pub const Build = struct {
    pub fn complete(node: *Node, _: *Frame) !void {
        const self = node.as(Script);
        const element = self.asElement();
        self._src = element.getAttributeSafe(comptime .wrap("src")) orelse "";
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Script" {
    try testing.htmlRunner("element/html/script", .{});
}

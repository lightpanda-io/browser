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

const log = @import("../../../../log.zig");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Script = @This();

_proto: *HtmlElement,
_src: []const u8 = "",
_on_load: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_executed: bool = false,

pub fn asElement(self: *Script) *Element {
    return self._proto._proto;
}

pub fn asConstElement(self: *const Script) *const Element {
    return self._proto._proto;
}

pub fn asNode(self: *Script) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Script) []const u8 {
    return self._src;
}

pub fn setSrc(self: *Script, src: []const u8, page: *Page) !void {
    const element = self.asElement();
    try element.setAttributeSafe("src", src, page);
    self._src = element.getAttributeSafe("src") orelse unreachable;
    if (element.asNode().isConnected()) {
        try page.scriptAddedCallback(false, self);
    }
}

pub fn getType(self: *const Script) []const u8 {
    return self.asConstElement().getAttributeSafe("type") orelse "";
}

pub fn setType(self: *Script, value: []const u8, page: *Page) !void {
    return self.asElement().setAttributeSafe("type", value, page);
}

pub fn getNonce(self: *const Script) []const u8 {
    return self.asConstElement().getAttributeSafe("nonce") orelse "";
}

pub fn setNonce(self: *Script, value: []const u8, page: *Page) !void {
    return self.asElement().setAttributeSafe("nonce", value, page);
}

pub fn getOnLoad(self: *const Script) ?js.Function.Global {
    return self._on_load;
}

pub fn setOnLoad(self: *Script, cb: ?js.Function.Global) void {
    self._on_load = cb;
}

pub fn getOnError(self: *const Script) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Script, cb: ?js.Function.Global) void {
    self._on_error = cb;
}

pub fn getNoModule(self: *const Script) bool {
    return self.asConstElement().getAttributeSafe("nomodule") != null;
}

pub fn setInnerText(self: *Script, text: []const u8, page: *Page) !void {
    try self.asNode().setTextContent(text, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Script);

    pub const Meta = struct {
        pub const name = "HTMLScriptElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const src = bridge.accessor(Script.getSrc, Script.setSrc, .{});
    pub const @"type" = bridge.accessor(Script.getType, Script.setType, .{});
    pub const nonce = bridge.accessor(Script.getNonce, Script.setNonce, .{});
    pub const onload = bridge.accessor(Script.getOnLoad, Script.setOnLoad, .{});
    pub const onerror = bridge.accessor(Script.getOnError, Script.setOnError, .{});
    pub const noModule = bridge.accessor(Script.getNoModule, null, .{});
    pub const innerText = bridge.accessor(_innerText, Script.setInnerText, .{});
    fn _innerText(self: *Script, page: *const Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.asNode().getTextContent(&buf.writer);
        return buf.written();
    }
};

pub const Build = struct {
    pub fn complete(node: *Node, page: *Page) !void {
        const self = node.as(Script);
        const element = self.asElement();
        self._src = element.getAttributeSafe("src") orelse "";

        if (element.getAttributeSafe("onload")) |on_load| {
            if (page.js.stringToFunction(on_load)) |func| {
                self._on_load = try func.persist();
            } else |err| {
                log.err(.js, "script.onload", .{ .err = err, .str = on_load });
            }
        }

        if (element.getAttributeSafe("onerror")) |on_error| {
            if (page.js.stringToFunction(on_error)) |func| {
                self._on_error = try func.persist();
            } else |err| {
                log.err(.js, "script.onerror", .{ .err = err, .str = on_error });
            }
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Script" {
    try testing.htmlRunner("element/html/script", .{});
}

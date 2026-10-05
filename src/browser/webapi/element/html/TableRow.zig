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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const collections = @import("../../collections.zig");

const HtmlElement = @import("../Html.zig");

const TableRow = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableRow) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableRow) *Node {
    return self.asElement().asNode();
}

fn getCells(self: *TableRow, frame: *Frame) collections.NodeLive(.cells) {
    return collections.NodeLive(.cells).init(self.asNode(), {}, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableRow);

    pub const Meta = struct {
        pub const name = "HTMLTableRowElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableRow);
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const @"align" = reflect.string("align");

    pub const cells = bridge.accessor(TableRow.getCells, null, .{});
};

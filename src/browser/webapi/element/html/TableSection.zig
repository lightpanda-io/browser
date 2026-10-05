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

const String = lp.String;

const TableSection = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableSection) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableSection) *Node {
    return self.asElement().asNode();
}

fn getRows(self: *TableSection, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tr, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableSection);

    pub const Meta = struct {
        pub const name = "HTMLTableSectionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableSection);
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const @"align" = reflect.string("align");

    pub const rows = bridge.accessor(TableSection.getRows, null, .{});
};

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
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;

const TableCell = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableCell) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableCell) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableCell);

    pub const Meta = struct {
        pub const name = "HTMLTableCellElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableCell);
    pub const scope = reflect.enumerated("scope", &.{ "row", "col", "rowgroup", "colgroup" }, .{});
    pub const noWrap = reflect.boolean("nowrap");
    pub const width = reflect.string("width");
    pub const vAlign = reflect.string("valign");
    pub const height = reflect.string("height");
    pub const headers = reflect.string("headers");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const axis = reflect.string("axis");
    pub const @"align" = reflect.string("align");
    pub const abbr = reflect.string("abbr");

    pub const colSpan = reflect.unsignedLong("colspan", .{ .default = 1, .clamp = .{ .min = 1, .max = 1000 } });
    pub const rowSpan = reflect.unsignedLong("rowspan", .{ .default = 1, .clamp = .{ .min = 0, .max = 65534 } });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TableCell" {
    try testing.htmlRunner("element/html/tablecell.html", .{});
}

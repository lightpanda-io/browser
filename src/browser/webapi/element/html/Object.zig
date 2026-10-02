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

const Object = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Object) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Object) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Object);

    pub const Meta = struct {
        pub const name = "HTMLObjectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Object);
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const data = reflect.url("data");
    pub const codeBase = reflect.url("codebase");
    pub const declare = reflect.boolean("declare");
    pub const width = reflect.string("width");
    pub const useMap = reflect.string("usemap");
    pub const @"type" = reflect.string("type");
    pub const standby = reflect.string("standby");
    pub const height = reflect.string("height");
    pub const codeType = reflect.string("codetype");
    pub const code = reflect.string("code");
    pub const border = reflect.stringNullToEmpty("border");
    pub const archive = reflect.string("archive");
    pub const @"align" = reflect.string("align");
    pub const name = reflect.string("name");
};

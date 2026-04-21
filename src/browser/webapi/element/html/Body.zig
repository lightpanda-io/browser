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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const log = lp.log;

const Body = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Body) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Body) *Node {
    return self.asElement().asNode();
}

/// Special-case: `body.onload` is actually an alias for `window.onload`.
pub fn setOnLoad(_: *Body, callback: ?js.Function.Global, frame: *Frame) !void {
    frame.window._on_load = callback;
}

/// Special-case: `body.onload` is actually an alias for `window.onload`.
pub fn getOnLoad(_: *Body, frame: *Frame) ?js.Function.Global {
    return frame.window._on_load;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Body);

    pub const Meta = struct {
        pub const name = "HTMLBodyElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onload = bridge.accessor(getOnLoad, setOnLoad, .{ .null_as_undefined = false });
};

pub const Build = struct {
    pub fn complete(node: *Node, frame: *Frame) !void {
        const el = node.as(Element);
        const on_load = el.getAttributeSafe(comptime .wrap("onload")) orelse return;
        if (frame.js.stringToPersistedFunction(on_load, &.{"event"}, &.{})) |func| {
            frame.window._on_load = func;
        } else |err| {
            log.err(.js, "body.onload", .{ .err = err, .str = on_load });
        }
    }
};

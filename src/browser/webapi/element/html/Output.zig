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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const HtmlElement = @import("../Html.zig");

const Output = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Output) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Output) *Node {
    return self.asElement().asNode();
}

pub fn getLabels(self: *Output, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub fn getHtmlFor(self: *Output, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    if (element._namespace != .html) {
        return null;
    }
    return element.getTokenList(.@"for", frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Output);

    pub const Meta = struct {
        pub const name = "HTMLOutputElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const labels = bridge.accessor(Output.getLabels, null, .{});
    pub const htmlFor = bridge.accessor(Output.getHtmlFor, null, .{ .null_as_undefined = true });
};

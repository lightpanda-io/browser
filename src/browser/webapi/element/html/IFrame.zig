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

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Window = @import("../../Window.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const IFrame = @This();
_proto: *HtmlElement,

pub fn asElement(self: *IFrame) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *IFrame) *Node {
    return self.asElement().asNode();
}

pub fn getContentWindow(_: *const IFrame, page: *Page) *Window {
    return page.window;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IFrame);

    pub const Meta = struct {
        pub const name = "HTMLIFrameElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const contentWindow = bridge.accessor(IFrame.getContentWindow, null, .{});
};

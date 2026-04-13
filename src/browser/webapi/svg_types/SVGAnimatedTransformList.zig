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

const SVGAnimatedTransformList = @This();

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const String = @import("../../../string.zig").String;
const SVGTransformList = @import("SVGTransformList.zig");

_element: *Element,
_attr_name: String,

pub fn getBaseVal(_: *const SVGAnimatedTransformList, page: *Page) !*SVGTransformList {
    return page._factory.create(SVGTransformList{});
}

pub fn getAnimVal(self: *const SVGAnimatedTransformList, page: *Page) !*SVGTransformList {
    return self.getBaseVal(page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGAnimatedTransformList);

    pub const Meta = struct {
        pub const name = "SVGAnimatedTransformList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(SVGAnimatedTransformList.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(SVGAnimatedTransformList.getAnimVal, null, .{});
};

// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const Element = @import("../dom/element.zig").Element;

// Support for SVGElements is very limited, this is a dummy implementation.
// This is here no to be able to support `element instanceof SVGElement;` in JavaScript.
// https://developer.mozilla.org/en-US/docs/Web/API/SVGElement
pub const SVGElement = struct {
    // Currently the prototype chain is not implemented (will not be returned by toInterface())
    // For that we need parser.SvgElement and the derived types with tags in the v-table.
    pub const prototype = *Element;
    // While this is a Node, could consider not exposing the subtype untill we have
    // a Self type to cast to.
    pub const subtype = .node;
};

const testing = @import("../../testing.zig");
test "Browser: HTML.SVGElement" {
    try testing.htmlRunner("html/svg.html");
}

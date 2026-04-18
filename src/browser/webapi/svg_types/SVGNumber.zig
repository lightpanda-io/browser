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

const SVGNumber = @This();

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const String = @import("../../../string.zig").String;

_element: ?*Element,
_attr_name: String,
_value: f64 = 0,

pub fn getValue(self: *const SVGNumber) f64 {
    if (self._element) |elem| {
        const attr = elem.getAttributeSafe(self._attr_name) orelse return 0;
        return std.fmt.parseFloat(f64, attr) catch 0;
    }
    return self._value;
}

pub fn setValue(self: *SVGNumber, value: f64, page: *Page) !void {
    self._value = value;
    if (self._element) |elem| {
        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        try elem.setAttributeSafe(self._attr_name, String.wrap(str), page);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGNumber);

    pub const Meta = struct {
        pub const name = "SVGNumber";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(SVGNumber.getValue, SVGNumber.setValue, .{});
};

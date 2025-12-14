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

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const HTMLCollection = @import("HTMLCollection.zig");

const HTMLFormControlsCollection = @This();

_proto: *HTMLCollection,

pub fn length(self: *HTMLFormControlsCollection, page: *Page) u32 {
    return self._proto.length(page);
}

pub fn getAtIndex(self: *HTMLFormControlsCollection, index: usize, page: *Page) ?*Element {
    return self._proto.getAtIndex(index, page);
}

pub fn namedItem(self: *HTMLFormControlsCollection, name: []const u8, page: *Page) ?*Element {
    // TODO: When multiple elements have same name (radio buttons),
    // should return RadioNodeList instead of first element
    return self._proto.getByName(name, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLFormControlsCollection);

    pub const Meta = struct {
        pub const name = "HTMLFormControlsCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const manage = false;
    };

    pub const length = bridge.accessor(HTMLFormControlsCollection.length, null, .{});
    pub const @"[int]" = bridge.indexed(HTMLFormControlsCollection.getAtIndex, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(HTMLFormControlsCollection.namedItem, null, null, .{ .null_as_undefined = true });
    pub const namedItem = bridge.function(HTMLFormControlsCollection.namedItem, .{});
};

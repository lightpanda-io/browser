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

pub const NodeLive = @import("collections/node_live.zig").NodeLive;
pub const ChildNodes = @import("collections/ChildNodes.zig");
pub const DOMTokenList = @import("collections/DOMTokenList.zig");
pub const HTMLAllCollection = @import("collections/HTMLAllCollection.zig");
pub const HTMLOptionsCollection = @import("collections/HTMLOptionsCollection.zig");

pub fn registerTypes() []const type {
    return &.{
        @import("collections/HTMLCollection.zig"),
        @import("collections/HTMLCollection.zig").Iterator,
        @import("collections/NodeList.zig"),
        @import("collections/NodeList.zig").KeyIterator,
        @import("collections/NodeList.zig").ValueIterator,
        @import("collections/NodeList.zig").EntryIterator,
        @import("collections/HTMLAllCollection.zig"),
        @import("collections/HTMLAllCollection.zig").Iterator,
        HTMLOptionsCollection,
        DOMTokenList,
        DOMTokenList.KeyIterator,
        DOMTokenList.ValueIterator,
        DOMTokenList.EntryIterator,
    };
}

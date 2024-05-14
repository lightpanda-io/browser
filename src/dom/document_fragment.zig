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

const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;

// WEB IDL https://dom.spec.whatwg.org/#documentfragment
pub const DocumentFragment = struct {
    pub const Self = parser.DocumentFragment;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // TODO add constructor, but I need to associate the new DocumentFragment
    // with the current document global object...
    // > The new DocumentFragment() constructor steps are to set this’s node
    // > document to current global object’s associated Document.
    // https://dom.spec.whatwg.org/#dom-documentfragment-documentfragment
    pub fn constructor() !*parser.DocumentFragment {
        return error.NotImplemented;
    }
};

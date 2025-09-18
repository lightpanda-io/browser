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

const DOMException = @import("exceptions.zig").DOMException;
const EventTarget = @import("event_target.zig").EventTarget;
const DOMImplementation = @import("implementation.zig").DOMImplementation;
const NamedNodeMap = @import("namednodemap.zig").NamedNodeMap;
const DOMTokenList = @import("token_list.zig");
const NodeList = @import("nodelist.zig");
const Node = @import("node.zig");
const ResizeObserver = @import("resize_observer.zig");
const MutationObserver = @import("mutation_observer.zig");
const DOMParser = @import("dom_parser.zig").DOMParser;
const TreeWalker = @import("tree_walker.zig").TreeWalker;
const NodeIterator = @import("node_iterator.zig").NodeIterator;
const NodeFilter = @import("node_filter.zig").NodeFilter;
const PerformanceObserver = @import("performance_observer.zig").PerformanceObserver;

pub const Interfaces = .{
    DOMException,
    EventTarget,
    DOMImplementation,
    NamedNodeMap,
    NamedNodeMap.Iterator,
    DOMTokenList.Interfaces,
    NodeList.Interfaces,
    Node.Node,
    Node.Interfaces,
    ResizeObserver.Interfaces,
    MutationObserver.Interfaces,
    DOMParser,
    TreeWalker,
    NodeIterator,
    NodeFilter,
    @import("performance.zig").Interfaces,
    PerformanceObserver,
    @import("range.zig").Interfaces,
    @import("Animation.zig"),
    @import("MessageChannel.zig").Interfaces,
    @import("IntersectionObserver.zig").Interfaces,
};

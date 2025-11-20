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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const DocumentFragment = @import("DocumentFragment.zig");
const Element = @import("Element.zig");

const ShadowRoot = @This();

pub const Mode = enum {
    open,
    closed,

    pub fn fromString(str: []const u8) !Mode {
        return std.meta.stringToEnum(Mode, str) orelse error.InvalidMode;
    }
};

_proto: *DocumentFragment,
_mode: Mode,
_host: *Element,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .{},

pub fn init(host: *Element, mode: Mode, page: *Page) !*ShadowRoot {
    return page._factory.documentFragment(ShadowRoot{
        ._proto = undefined,
        ._mode = mode,
        ._host = host,
    });
}

pub fn asDocumentFragment(self: *ShadowRoot) *DocumentFragment {
    return self._proto;
}

pub fn asNode(self: *ShadowRoot) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *ShadowRoot) *@import("EventTarget.zig") {
    return self.asNode().asEventTarget();
}

pub fn className(_: *const ShadowRoot) []const u8 {
    return "[object ShadowRoot]";
}

pub fn getMode(self: *const ShadowRoot) []const u8 {
    return @tagName(self._mode);
}

pub fn getHost(self: *const ShadowRoot) *Element {
    return self._host;
}

pub fn getElementById(self: *ShadowRoot, id_: ?[]const u8) ?*Element {
    const id = id_ orelse return null;
    return self._elements_by_id.get(id);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ShadowRoot);

    pub const Meta = struct {
        pub const name = "ShadowRoot";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const mode = bridge.accessor(ShadowRoot.getMode, null, .{});
    pub const host = bridge.accessor(ShadowRoot.getHost, null, .{});
    pub const getElementById = bridge.function(ShadowRoot.getElementById, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ShadowRoot" {
    try testing.htmlRunner("shadowroot", .{});
}

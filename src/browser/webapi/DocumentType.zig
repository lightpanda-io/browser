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

const DocumentType = @This();

_proto: *Node,
_name: []const u8,
_public_id: []const u8,
_system_id: []const u8,

pub fn init(qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, page: *Page) !*DocumentType {
    const name = try page.dupeString(qualified_name);
    // Firefox converts null to the string "null", not empty string
    const pub_id = if (public_id) |p| try page.dupeString(p) else "null";
    const sys_id = if (system_id) |s| try page.dupeString(s) else "null";

    return page._factory.node(DocumentType{
        ._proto = undefined,
        ._name = name,
        ._public_id = pub_id,
        ._system_id = sys_id,
    });
}

pub fn asNode(self: *DocumentType) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *DocumentType) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getName(self: *const DocumentType) []const u8 {
    return self._name;
}

pub fn getPublicId(self: *const DocumentType) []const u8 {
    return self._public_id;
}

pub fn getSystemId(self: *const DocumentType) []const u8 {
    return self._system_id;
}

pub fn isEqualNode(self: *const DocumentType, other: *const DocumentType) bool {
    return std.mem.eql(u8, self._name, other._name) and
        std.mem.eql(u8, self._public_id, other._public_id) and
        std.mem.eql(u8, self._system_id, other._system_id);
}

pub fn clone(self: *const DocumentType, page: *Page) !*DocumentType {
    return .init(self._name, self._public_id, self._system_id, page);
}

pub fn remove(self: *DocumentType, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    _ = try parent.removeChild(node, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentType);

    pub const Meta = struct {
        pub const name = "DocumentType";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const name = bridge.accessor(DocumentType.getName, null, .{});
    pub const publicId = bridge.accessor(DocumentType.getPublicId, null, .{});
    pub const systemId = bridge.accessor(DocumentType.getSystemId, null, .{});
    pub const remove = bridge.function(DocumentType.remove, .{});
};

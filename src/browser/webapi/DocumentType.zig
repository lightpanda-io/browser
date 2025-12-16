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

pub fn className(_: *const DocumentType) []const u8 {
    return "[object DocumentType]";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentType);

    pub const Meta = struct {
        pub const name = "DocumentType";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(DocumentType.getName, null, .{});
    pub const publicId = bridge.accessor(DocumentType.getPublicId, null, .{});
    pub const systemId = bridge.accessor(DocumentType.getSystemId, null, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(self: *const DocumentType) []const u8 {
        return self.className();
    }
};

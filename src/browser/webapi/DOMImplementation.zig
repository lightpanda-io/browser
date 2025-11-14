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
const DocumentType = @import("DocumentType.zig");

const DOMImplementation = @This();

pub fn createDocumentType(_: *const DOMImplementation, qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, page: *Page) !*DocumentType {
    const name = try page.dupeString(qualified_name);
    const pub_id = try page.dupeString(public_id orelse "");
    const sys_id = try page.dupeString(system_id orelse "");

    const doctype = try page._factory.node(DocumentType{
        ._proto = undefined,
        ._name = name,
        ._public_id = pub_id,
        ._system_id = sys_id,
    });

    return doctype;
}

pub fn hasFeature(_: *const DOMImplementation, _: []const u8, _: ?[]const u8) bool {
    // Modern DOM spec says this should always return true
    // This method is deprecated and kept for compatibility only
    return true;
}

pub fn className(_: *const DOMImplementation) []const u8 {
    return "[object DOMImplementation]";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMImplementation);

    pub const Meta = struct {
        pub const name = "DOMImplementation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const createDocumentType = bridge.function(DOMImplementation.createDocumentType, .{ .dom_exception = true });
    pub const hasFeature = bridge.function(DOMImplementation.hasFeature, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(_: *const DOMImplementation) []const u8 {
        return "[object DOMImplementation]";
    }
};

const testing = @import("../../testing.zig");
test "WebApi: DOMImplementation" {
    try testing.htmlRunner("domimplementation.html", .{});
}

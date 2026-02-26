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

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const Input = @import("../element/html/Input.zig");

const NodeList = @import("NodeList.zig");
const HTMLFormControlsCollection = @import("HTMLFormControlsCollection.zig");

const RadioNodeList = @This();

_proto: *NodeList,
_name: []const u8,
_form_collection: *HTMLFormControlsCollection,

pub fn getLength(self: *RadioNodeList) !u32 {
    var i: u32 = 0;
    var it = try self._form_collection.iterator();
    while (it.next()) |element| {
        if (self.matches(element)) {
            i += 1;
        }
    }
    return i;
}

pub fn getAtIndex(self: *RadioNodeList, index: usize, page: *Page) !?*Node {
    var i: usize = 0;
    var current: usize = 0;
    while (self._form_collection.getAtIndex(i, page)) |element| : (i += 1) {
        if (!self.matches(element)) {
            continue;
        }
        if (current == index) {
            return element.asNode();
        }
        current += 1;
    }
    return null;
}

pub fn getValue(self: *RadioNodeList) ![]const u8 {
    var it = try self._form_collection.iterator();
    while (it.next()) |element| {
        const input = element.is(Input) orelse continue;
        if (input._input_type != .radio) {
            continue;
        }
        if (!input.getChecked()) {
            continue;
        }
        return element.getAttributeSafe(comptime .wrap("value")) orelse "on";
    }
    return "";
}

pub fn setValue(self: *RadioNodeList, value: []const u8, page: *Page) !void {
    var it = try self._form_collection.iterator();
    while (it.next()) |element| {
        const input = element.is(Input) orelse continue;
        if (input._input_type != .radio) {
            continue;
        }

        const input_value = element.getAttributeSafe(comptime .wrap("value"));
        const matches_value = blk: {
            if (std.mem.eql(u8, value, "on")) {
                break :blk input_value == null or (input_value != null and std.mem.eql(u8, input_value.?, "on"));
            } else {
                break :blk input_value != null and std.mem.eql(u8, input_value.?, value);
            }
        };

        if (matches_value) {
            try input.setChecked(true, page);
            return;
        }
    }
}

fn matches(self: *const RadioNodeList, element: *Element) bool {
    if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (std.mem.eql(u8, id, self._name)) {
            return true;
        }
    }
    if (element.getAttributeSafe(comptime .wrap("name"))) |elem_name| {
        if (std.mem.eql(u8, elem_name, self._name)) {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RadioNodeList);

    pub const Meta = struct {
        pub const name = "RadioNodeList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(RadioNodeList.getLength, null, .{});
    pub const @"[]" = bridge.indexed(RadioNodeList.getAtIndex, null, .{ .null_as_undefined = true });
    pub const item = bridge.function(RadioNodeList.getAtIndex, .{});
    pub const value = bridge.accessor(RadioNodeList.getValue, RadioNodeList.setValue, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: RadioNodeList" {
    try testing.htmlRunner("collections/radio_node_list.html", .{});
}

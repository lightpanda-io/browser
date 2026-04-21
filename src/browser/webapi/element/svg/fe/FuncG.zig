// Copyright (C) 2023-2025  Lightpanda Selecy SAS
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const js = @import("../../../../js/js.zig");
const Node = @import("../../../Node.zig");
const Element = @import("../../../Element.zig");
const Svg = @import("../../Svg.zig");
const String = @import("../../../../../string.zig").String;

const FuncG = @This();
_proto: *Svg,

pub fn asElement(self: *FuncG) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FuncG) *Node {
    return self.asElement().asNode();
}

pub fn get_type(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("type")) orelse "";
}
pub fn get_tableValues(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("tableValues")) orelse "";
}
pub fn get_slope(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("slope")) orelse "";
}
pub fn get_intercept(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("intercept")) orelse "";
}
pub fn get_amplitude(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("amplitude")) orelse "";
}
pub fn get_exponent(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("exponent")) orelse "";
}
pub fn get_offset(self: *FuncG) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("offset")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FuncG);
    pub const Meta = struct {
        pub const name = "SVGFEFuncGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"type" = bridge.accessor(FuncG.get_type, null, .{});
    pub const tableValues = bridge.accessor(FuncG.get_tableValues, null, .{});
    pub const slope = bridge.accessor(FuncG.get_slope, null, .{});
    pub const intercept = bridge.accessor(FuncG.get_intercept, null, .{});
    pub const amplitude = bridge.accessor(FuncG.get_amplitude, null, .{});
    pub const exponent = bridge.accessor(FuncG.get_exponent, null, .{});
    pub const offset = bridge.accessor(FuncG.get_offset, null, .{});
};

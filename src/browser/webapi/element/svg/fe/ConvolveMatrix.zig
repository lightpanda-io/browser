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

const ConvolveMatrix = @This();
_proto: *Svg,

pub fn asElement(self: *ConvolveMatrix) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *ConvolveMatrix) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_in(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "in"); }
fn getOrder(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "order"); }
pub fn get_orderX(self: *ConvolveMatrix) []const u8 {
    const val = self.getOrder();
    if (std.mem.indexOf(u8, val, " ")) |idx| return val[0..idx];
    return val;
}
pub fn get_orderY(self: *ConvolveMatrix) []const u8 {
    const val = self.getOrder();
    if (std.mem.indexOf(u8, val, " ")) |idx| return std.mem.trimLeft(u8, val[idx + 1 ..], " ");
    return val;
}
pub fn get_kernelUnitLengthX(self: *ConvolveMatrix) []const u8 {
    const val = self.asElement().getAttributeSafe(String.wrap("kernelUnitLength")) orelse "";
    if (std.mem.indexOf(u8, val, " ")) |idx| return val[0..idx];
    return val;
}
pub fn get_kernelUnitLengthY(self: *ConvolveMatrix) []const u8 {
    const val = self.asElement().getAttributeSafe(String.wrap("kernelUnitLength")) orelse "";
    if (std.mem.indexOf(u8, val, " ")) |idx| return std.mem.trimLeft(u8, val[idx + 1..], " ");
    return val;
}
pub fn get_kernelMatrix(self: *ConvolveMatrix) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("kernelMatrix")) orelse "";
}
pub fn get_targetX(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "targetX"); }
pub fn get_targetY(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "targetY"); }
pub fn get_edgeMode(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "edgeMode"); }
pub fn get_preserveAlpha(self: *ConvolveMatrix) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("preserveAlpha")) orelse "";
}
pub fn get_divisor(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "divisor"); }
pub fn get_bias(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "bias"); }
pub fn get_x(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "x"); }
pub fn get_y(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "y"); }
pub fn get_width(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "width"); }
pub fn get_height(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "height"); }
pub fn get_result(self: *ConvolveMatrix) []const u8 { return getAttr(self.asElement(), "result"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(ConvolveMatrix);
    pub const Meta = struct {
        pub const name = "SVGFEConvolveMatrixElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(ConvolveMatrix.get_in, null, .{});
    pub const orderX = bridge.accessor(ConvolveMatrix.get_orderX, null, .{});
    pub const orderY = bridge.accessor(ConvolveMatrix.get_orderY, null, .{});
    pub const kernelUnitLengthX = bridge.accessor(ConvolveMatrix.get_kernelUnitLengthX, null, .{});
    pub const kernelUnitLengthY = bridge.accessor(ConvolveMatrix.get_kernelUnitLengthY, null, .{});
    pub const kernelMatrix = bridge.accessor(ConvolveMatrix.get_kernelMatrix, null, .{});
    pub const targetX = bridge.accessor(ConvolveMatrix.get_targetX, null, .{});
    pub const targetY = bridge.accessor(ConvolveMatrix.get_targetY, null, .{});
    pub const edgeMode = bridge.accessor(ConvolveMatrix.get_edgeMode, null, .{});
    pub const preserveAlpha = bridge.accessor(ConvolveMatrix.get_preserveAlpha, null, .{});
    pub const divisor = bridge.accessor(ConvolveMatrix.get_divisor, null, .{});
    pub const bias = bridge.accessor(ConvolveMatrix.get_bias, null, .{});
    pub const x = bridge.accessor(ConvolveMatrix.get_x, null, .{});
    pub const y = bridge.accessor(ConvolveMatrix.get_y, null, .{});
    pub const width = bridge.accessor(ConvolveMatrix.get_width, null, .{});
    pub const height = bridge.accessor(ConvolveMatrix.get_height, null, .{});
    pub const result = bridge.accessor(ConvolveMatrix.get_result, null, .{});
};

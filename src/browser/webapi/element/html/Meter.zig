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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");

const Meter = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Meter) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Meter) *Node {
    return self.asElement().asNode();
}

fn attribute(self: *const Meter, comptime name: []const u8) ?f64 {
    return reflection.getDouble(Factory.protoOf(self).asElement(), name);
}

fn getMin(self: *const Meter) f64 {
    return self.attribute("min") orelse 0;
}

fn getMax(self: *const Meter) f64 {
    return @max(self.attribute("max") orelse 1, self.getMin());
}

fn getValue(self: *const Meter) f64 {
    return std.math.clamp(self.attribute("value") orelse 0, self.getMin(), self.getMax());
}

fn getLow(self: *const Meter) f64 {
    const min = self.getMin();
    return std.math.clamp(self.attribute("low") orelse min, min, self.getMax());
}

fn getHigh(self: *const Meter) f64 {
    const max = self.getMax();
    return std.math.clamp(self.attribute("high") orelse max, self.getLow(), max);
}

fn getOptimum(self: *const Meter) f64 {
    const min = self.getMin();
    const max = self.getMax();
    return std.math.clamp(self.attribute("optimum") orelse (min + max) / 2, min, max);
}

fn setter(comptime name: []const u8) fn (*Meter, f64, *Frame) anyerror!void {
    return struct {
        fn set(self: *Meter, value: f64, frame: *Frame) !void {
            return reflection.setDouble(self.asElement(), name, value, frame);
        }
    }.set;
}

fn getLabels(self: *Meter, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Meter);

    pub const Meta = struct {
        pub const name = "HTMLMeterElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Meter.getValue, setter("value"), .{ .ce_reactions = true });
    pub const min = bridge.accessor(Meter.getMin, setter("min"), .{ .ce_reactions = true });
    pub const max = bridge.accessor(Meter.getMax, setter("max"), .{ .ce_reactions = true });
    pub const low = bridge.accessor(Meter.getLow, setter("low"), .{ .ce_reactions = true });
    pub const high = bridge.accessor(Meter.getHigh, setter("high"), .{ .ce_reactions = true });
    pub const optimum = bridge.accessor(Meter.getOptimum, setter("optimum"), .{ .ce_reactions = true });
    pub const labels = bridge.accessor(Meter.getLabels, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Meter" {
    try testing.htmlRunner("element/html/meter.html", .{});
}

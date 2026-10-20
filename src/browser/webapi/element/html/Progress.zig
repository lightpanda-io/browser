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

const Progress = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Progress) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Progress) *Node {
    return self.asElement().asNode();
}

// "limited to only positive numbers", default 1
fn getMax(self: *const Progress) f64 {
    const max = reflection.getDouble(Factory.protoOf(self).asElement(), "max") orelse return 1;
    return if (max > 0) max else 1;
}

fn setMax(self: *Progress, value: f64, frame: *Frame) !void {
    if (std.math.isFinite(value) and value <= 0) {
        return;
    }
    return reflection.setDouble(self.asElement(), "max", value, frame);
}

fn currentValue(self: *const Progress) ?f64 {
    const el = Factory.protoOf(self).asElement();
    if (el.getAttributeSafe(comptime .wrap("value")) == null) {
        // null when there's no value...
        return null;
    }
    // but 0 when when the value is not parsable.
    const value = reflection.getDouble(el, "value") orelse 0;
    return std.math.clamp(value, 0, self.getMax());
}

fn getValue(self: *const Progress) f64 {
    return self.currentValue() orelse 0;
}

fn setValue(self: *Progress, value: f64, frame: *Frame) !void {
    return reflection.setDouble(self.asElement(), "value", value, frame);
}

fn getPosition(self: *const Progress) f64 {
    const value = self.currentValue() orelse return -1;
    return value / self.getMax();
}

fn getLabels(self: *Progress, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Progress);

    pub const Meta = struct {
        pub const name = "HTMLProgressElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const max = bridge.accessor(Progress.getMax, Progress.setMax, .{ .ce_reactions = true });
    pub const value = bridge.accessor(Progress.getValue, Progress.setValue, .{ .ce_reactions = true });
    pub const position = bridge.accessor(Progress.getPosition, null, .{});

    pub const labels = bridge.accessor(Progress.getLabels, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Progress" {
    try testing.htmlRunner("element/html/progress.html", .{});
}

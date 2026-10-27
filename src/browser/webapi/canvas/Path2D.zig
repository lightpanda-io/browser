// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("../../js/js.zig");

const Execution = js.Execution;

const Path2D = @This();

const Source = union(enum) {
    path: *Path2D, // must be first, anything can be coerced to a string
    svg: []const u8,
};

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

fn init(_: ?Source, exec: *const Execution) !*Path2D {
    return exec._factory.create(Path2D{});
}

fn addPath(_: *Path2D, _: *Path2D, _: ?js.Value) void {}
fn closePath(_: *Path2D) void {}
fn moveTo(_: *Path2D, _: f64, _: f64) void {}
fn lineTo(_: *Path2D, _: f64, _: f64) void {}
fn quadraticCurveTo(_: *Path2D, _: f64, _: f64, _: f64, _: f64) void {}
fn bezierCurveTo(_: *Path2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
fn arc(_: *Path2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
fn arcTo(_: *Path2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
fn ellipse(_: *Path2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
fn rect(_: *Path2D, _: f64, _: f64, _: f64, _: f64) void {}
fn roundRect(_: *Path2D, _: f64, _: f64, _: f64, _: f64, _: ?js.Value) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Path2D);

    pub const Meta = struct {
        pub const name = "Path2D";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Path2D.init, .{});
    pub const addPath = bridge.function(Path2D.addPath, .{});
    pub const closePath = bridge.function(Path2D.closePath, .{ .noop = true });
    pub const moveTo = bridge.function(Path2D.moveTo, .{ .noop = true });
    pub const lineTo = bridge.function(Path2D.lineTo, .{ .noop = true });
    pub const quadraticCurveTo = bridge.function(Path2D.quadraticCurveTo, .{ .noop = true });
    pub const bezierCurveTo = bridge.function(Path2D.bezierCurveTo, .{ .noop = true });
    pub const arc = bridge.function(Path2D.arc, .{ .noop = true });
    pub const arcTo = bridge.function(Path2D.arcTo, .{ .noop = true });
    pub const ellipse = bridge.function(Path2D.ellipse, .{ .noop = true });
    pub const rect = bridge.function(Path2D.rect, .{ .noop = true });
    pub const roundRect = bridge.function(Path2D.roundRect, .{ .noop = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: Path2D" {
    try testing.htmlRunner("canvas/path2d.html", .{});
}

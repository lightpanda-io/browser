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

/// Nothing is painted, so a pattern only has to exist.
const CanvasPattern = @This();

_repetition: []const u8,

pub fn init(repetition: []const u8, exec: *const Execution) !*CanvasPattern {
    return exec._factory.create(CanvasPattern{ ._repetition = repetition });
}

pub fn setTransform(_: *const CanvasPattern, _: ?js.Value) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasPattern);

    pub const Meta = struct {
        pub const name = "CanvasPattern";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const setTransform = bridge.function(CanvasPattern.setTransform, .{ .noop = true });
};

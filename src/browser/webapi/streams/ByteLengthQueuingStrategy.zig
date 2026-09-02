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

const ByteLengthQueuingStrategy = @This();

_high_water_mark: f64,

const Init = struct {
    highWaterMark: f64,
};

pub fn init(init_: Init, exec: *const Execution) !*ByteLengthQueuingStrategy {
    return exec._factory.create(ByteLengthQueuingStrategy{ ._high_water_mark = init_.highWaterMark });
}

pub fn getHighWaterMark(self: *const ByteLengthQueuingStrategy) f64 {
    return self._high_water_mark;
}

// GetV(chunk, "byteLength"): objects report their byteLength (or undefined
// without one), other primitives have no such property, null/undefined throw.
const Chunk = union(enum) {
    sized: struct { byteLength: ?f64 },
    other: js.Value,
};

pub fn size(_: *const ByteLengthQueuingStrategy, chunk: Chunk) !?f64 {
    return switch (chunk) {
        .sized => |sized| sized.byteLength,
        .other => |value| if (value.isNullOrUndefined()) error.TypeError else null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ByteLengthQueuingStrategy);

    pub const Meta = struct {
        pub const name = "ByteLengthQueuingStrategy";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ByteLengthQueuingStrategy.init, .{});
    pub const highWaterMark = bridge.accessor(ByteLengthQueuingStrategy.getHighWaterMark, null, .{});
    pub const size = bridge.function(ByteLengthQueuingStrategy.size, .{ .null_as_undefined = true });
};

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
const Element = @import("Element.zig");

pub const ResizeObserver = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

fn init(cbk: js.Function) ResizeObserver {
    _ = cbk;
    return .{};
}

const Options = struct {
    box: []const u8,
};
pub fn observe(self: *const ResizeObserver, element: *Element, options_: ?Options) void {
    _ = self;
    _ = element;
    _ = options_;
    return;
}

pub fn unobserve(self: *const ResizeObserver, element: *Element) void {
    _ = self;
    _ = element;
    return;
}

pub fn disconnect(self: *const ResizeObserver) void {
    _ = self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ResizeObserver);

    pub const Meta = struct {
        pub const name = "ResizeObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(ResizeObserver.init, .{});
    pub const observe = bridge.function(ResizeObserver.observe, .{});
    pub const disconnect = bridge.function(ResizeObserver.disconnect, .{});
};

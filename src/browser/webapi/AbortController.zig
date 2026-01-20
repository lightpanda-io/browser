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
const AbortSignal = @import("AbortSignal.zig");

const AbortController = @This();

_signal: *AbortSignal,

pub fn init(page: *Page) !*AbortController {
    const signal = try AbortSignal.init(page);
    return page._factory.create(AbortController{
        ._signal = signal,
    });
}

pub fn getSignal(self: *const AbortController) *AbortSignal {
    return self._signal;
}

pub fn abort(self: *AbortController, reason_: ?js.Value.Global, page: *Page) !void {
    try self._signal.abort(if (reason_) |r| .{ .js_val = r } else null, page.js.local.?, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbortController);

    pub const Meta = struct {
        pub const name = "AbortController";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AbortController.init, .{});
    pub const signal = bridge.accessor(AbortController.getSignal, null, .{});
    pub const abort = bridge.function(AbortController.abort, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: AbortController" {
    try testing.htmlRunner("event/abort_controller.html", .{});
}

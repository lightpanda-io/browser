// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("netsurf");
const Event = @import("../events/event.zig").Event;

const DOMException = @import("../dom/exceptions.zig").DOMException;

pub const ProgressEvent = struct {
    pub const prototype = *Event;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    pub const EventInit = struct {
        lengthComputable: bool = false,
        loaded: u64 = 0,
        total: u64 = 0,
    };

    proto: parser.Event,
    lengthComputable: bool,
    loaded: u64 = 0,
    total: u64 = 0,

    pub fn constructor(eventType: []const u8, opts: ?EventInit) !ProgressEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, eventType, .{});
        try parser.eventSetInternalType(event, .progress_event);

        const o = opts orelse EventInit{};

        return .{
            .proto = event.*,
            .lengthComputable = o.lengthComputable,
            .loaded = o.loaded,
            .total = o.total,
        };
    }

    pub fn get_lengthComputable(self: ProgressEvent) bool {
        return self.lengthComputable;
    }

    pub fn get_loaded(self: ProgressEvent) u64 {
        return self.loaded;
    }

    pub fn get_total(self: ProgressEvent) u64 {
        return self.total;
    }
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var progress_event = [_]Case{
        .{ .src = "let pevt = new ProgressEvent('foo');", .ex = "undefined" },
        .{ .src = "pevt.loaded", .ex = "0" },
        .{ .src = "pevt instanceof ProgressEvent", .ex = "true" },
        .{ .src = "var nnb = 0; var eevt = null; function ccbk(event) { nnb ++; eevt = event; }", .ex = "undefined" },
        .{ .src = "document.addEventListener('foo', ccbk)", .ex = "undefined" },
        .{ .src = "document.dispatchEvent(pevt)", .ex = "true" },
        .{ .src = "eevt.type", .ex = "foo" },
        .{ .src = "eevt instanceof ProgressEvent", .ex = "true" },
    };
    try checkCases(js_env, &progress_event);
}

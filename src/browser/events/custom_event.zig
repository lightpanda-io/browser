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

const parser = @import("../netsurf.zig");
const Event = @import("event.zig").Event;
const JsObject = @import("../env.zig").JsObject;

// https://dom.spec.whatwg.org/#interface-customevent
pub const CustomEvent = struct {
    pub const prototype = *Event;
    pub const union_make_copy = true;

    proto: parser.Event,
    detail: ?JsObject,

    const CustomEventInit = struct {
        bubbles: bool = false,
        cancelable: bool = false,
        composed: bool = false,
        detail: ?JsObject = null,
    };

    pub fn constructor(event_type: []const u8, opts_: ?CustomEventInit) !CustomEvent {
        const opts = opts_ orelse CustomEventInit{};

        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{
            .bubbles = opts.bubbles,
            .cancelable = opts.cancelable,
            .composed = opts.composed,
        });

        return .{
            .proto = event.*,
            .detail = if (opts.detail) |d| try d.persist() else null,
        };
    }

    pub fn get_detail(self: *CustomEvent) ?JsObject {
        return self.detail;
    }
};

const testing = @import("../../testing.zig");
test "Browser.CustomEvent" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let capture = null", "undefined" },
        .{ "const el = document.createElement('div');", "undefined" },
        .{ "el.addEventListener('c1', (e) => { capture = 'c1-' + new String(e.detail)})", "undefined" },
        .{ "el.addEventListener('c2', (e) => { capture = 'c2-' + new String(e.detail.over)})", "undefined" },

        .{ "el.dispatchEvent(new CustomEvent('c1'));", "true" },
        .{ "capture", "c1-null" },

        .{ "el.dispatchEvent(new CustomEvent('c1', {detail: '123'}));", "true" },
        .{ "capture", "c1-123" },

        .{ "el.dispatchEvent(new CustomEvent('c2', {detail: {over: 9000}}));", "true" },
        .{ "capture", "c2-9000" },
    }, .{});
}

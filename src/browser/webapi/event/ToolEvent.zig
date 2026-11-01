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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");

const String = lp.String;

pub fn registerTypes() []const type {
    return &.{ ToolActivatedEvent, ToolCancelEvent };
}

// https://webmachinelearning.github.io/webmcp/#toolactivatedevent
pub const ToolActivatedEvent = ToolEvent("ToolActivatedEvent", "toolactivated");
pub const ToolCancelEvent = ToolEvent("ToolCancelEvent", "toolcancel");

/// The two WebMCP execution events differ only in name: both carry the name
/// of the tool, and fire at the ModelContext running it.
fn ToolEvent(comptime class_name: []const u8, comptime event_type_: []const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = Event;
        pub const event_type = event_type_;

        _proto: *Event,
        _tool_name: []const u8,

        const ToolEventOptions = struct {
            toolName: []const u8 = "",
        };

        const Options = Event.inheritOptions(Self, ToolEventOptions);

        pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*Self {
            const arena = try page.getArena(.tiny, class_name);
            errdefer arena.release();
            const type_string = try String.init(arena.allocator(), typ, .{});
            return initWithTrusted(arena, type_string, opts_ orelse .{}, false, page);
        }

        pub fn initTrusted(tool_name: []const u8, page: *Page) !*Self {
            const arena = try page.getArena(.tiny, class_name ++ ".trusted");
            errdefer arena.release();
            return initWithTrusted(arena, .wrap(event_type_), .{ .toolName = tool_name }, true, page);
        }

        fn initWithTrusted(arena: *lp.Arena, typ: String, opts: Options, trusted: bool, page: *Page) !*Self {
            const event = try page.factory.event(
                arena,
                typ,
                Self{
                    ._proto = undefined,
                    ._tool_name = try arena.allocator().dupe(u8, opts.toolName),
                },
            );

            Event.populatePrototypes(event, opts, trusted);
            return event;
        }

        pub fn asEvent(self: *Self) *Event {
            return self._proto;
        }

        fn getToolName(self: *const Self) []const u8 {
            return self._tool_name;
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = class_name;
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const constructor = bridge.constructor(Self.init, .{});
            pub const toolName = bridge.accessor(Self.getToolName, null, .{});
        };
    };
}

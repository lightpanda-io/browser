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
const Scheduler = @import("../Scheduler.zig");

const String = lp.String;

/// https://wicg.github.io/scheduling-apis/#sec-task-priority-change-event
const TaskPriorityChangeEvent = @This();

pub const Proto = Event;

_proto: *Event,
_previous_priority: Scheduler.Priority,

const TaskPriorityChangeEventOptions = struct {
    previousPriority: Scheduler.Priority,
};

const Options = Event.inheritOptions(TaskPriorityChangeEvent, TaskPriorityChangeEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*TaskPriorityChangeEvent {
    // previousPriority is a required member
    const opts = opts_ orelse return error.TypeError;
    const arena = try page.getArena(.tiny, "TaskPriorityChangeEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts, false, page);
}

pub fn initTrusted(opts: Options, page: *Page) !*TaskPriorityChangeEvent {
    const arena = try page.getArena(.tiny, "TaskPriorityChangeEvent.trusted");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), "prioritychange", .{});
    return initWithTrusted(arena, type_string, opts, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts: Options, trusted: bool, page: *Page) !*TaskPriorityChangeEvent {
    const event = try page.factory.event(
        arena,
        typ,
        TaskPriorityChangeEvent{
            ._proto = undefined,
            ._previous_priority = opts.previousPriority,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *TaskPriorityChangeEvent) *Event {
    return self._proto;
}

pub fn getPreviousPriority(self: *const TaskPriorityChangeEvent) Scheduler.Priority {
    return self._previous_priority;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TaskPriorityChangeEvent);

    pub const Meta = struct {
        pub const name = "TaskPriorityChangeEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TaskPriorityChangeEvent.init, .{});
    pub const previousPriority = bridge.accessor(TaskPriorityChangeEvent.getPreviousPriority, null, .{});
};

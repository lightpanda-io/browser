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

const js = @import("../js/js.zig");

const Scheduler = @import("Scheduler.zig");
const AbortSignal = @import("AbortSignal.zig");
const EventTarget = @import("EventTarget.zig");
const TaskPriorityChangeEvent = @import("event/TaskPriorityChangeEvent.zig");

const Execution = js.Execution;

// https://wicg.github.io/scheduling-apis/#sec-task-signal
const TaskSignal = @This();

pub const Proto = AbortSignal;

_proto: *AbortSignal,
_priority: Scheduler.Priority,
_priority_changing: bool = false,
_on_prioritychange: ?js.Function.Global = null,

pub fn init(priority: Scheduler.Priority, exec: *const Execution) !*TaskSignal {
    return exec._factory.taskSignal(TaskSignal{
        ._proto = undefined,
        ._priority = priority,
    });
}

pub fn asAbortSignal(self: *TaskSignal) *AbortSignal {
    return self._proto;
}

pub fn asEventTarget(self: *TaskSignal) *EventTarget {
    return self._proto.asEventTarget();
}

pub fn getPriority(self: *const TaskSignal) Scheduler.Priority {
    return self._priority;
}

pub fn getOnPriorityChange(self: *const TaskSignal) ?js.Function.Global {
    return self._on_prioritychange;
}

pub fn setOnPriorityChange(self: *TaskSignal, cb: ?js.Function.Global) !void {
    self._on_prioritychange = cb;
}

pub fn setPriority(self: *TaskSignal, priority: Scheduler.Priority, exec: *const Execution) !void {
    if (self._priority_changing) {
        // re-entrant priority changes (from a prioritychange listener) throw.
        return error.NotSupportedError;
    }
    if (priority == self._priority) {
        return;
    }
    self._priority_changing = true;
    defer self._priority_changing = false;

    const previous = self._priority;
    self._priority = priority;

    const target = self.asEventTarget();
    const on_prioritychange = self._on_prioritychange;
    if (exec.hasDirectListeners(target, "prioritychange", on_prioritychange)) {
        const event = try TaskPriorityChangeEvent.initTrusted(.{ .previousPriority = previous }, exec.page);
        try exec.dispatch(target, event.asEvent(), on_prioritychange, .{ .context = "task signal" });
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TaskSignal);

    pub const Meta = struct {
        pub const name = "TaskSignal";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const priority = bridge.accessor(TaskSignal.getPriority, null, .{});
    pub const onprioritychange = bridge.accessor(TaskSignal.getOnPriorityChange, TaskSignal.setOnPriorityChange, .{});
};

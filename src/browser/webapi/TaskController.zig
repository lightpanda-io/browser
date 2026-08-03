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
const TaskSignal = @import("TaskSignal.zig");
const AbortController = @import("AbortController.zig");

const Execution = js.Execution;

// https://wicg.github.io/scheduling-apis/#sec-task-controller
const TaskController = @This();

pub const Proto = AbortController;

_proto: *AbortController,

const Options = struct {
    priority: Scheduler.Priority = .@"user-visible",
};

pub fn init(options_: ?Options, exec: *const Execution) !*TaskController {
    const opts = options_ orelse Options{};
    const signal = try TaskSignal.init(opts.priority, exec);
    return exec._factory.chained(.{
        AbortController{ ._signal = signal.asAbortSignal() },
        TaskController{ ._proto = undefined },
    });
}

pub fn setPriority(self: *TaskController, priority: Scheduler.Priority, exec: *const Execution) !void {
    return self._proto._signal._type.task_signal.setPriority(priority, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TaskController);

    pub const Meta = struct {
        pub const name = "TaskController";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TaskController.init, .{});
    pub const setPriority = bridge.function(TaskController.setPriority, .{});
};

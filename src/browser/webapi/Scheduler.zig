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

const js = @import("../js/js.zig");

const AbortSignal = @import("AbortSignal.zig");

const Execution = js.Execution;

const Scheduler = @This();

// State of the postTask callback (or yield continuation) currently running,
// so scheduler.yield() can inherit its priority and abort signal.
_current: ?TaskState = null,

pub const Priority = enum {
    @"user-blocking",
    @"user-visible",
    background,

    pub const js_enum_from_string = true;

    pub fn toString(self: Priority) []const u8 {
        return @tagName(self);
    }
};

const TaskState = struct {
    priority: Priority,
    signal: ?*AbortSignal,
};

const PostTaskOptions = struct {
    delay: ?u32 = null,
    priority: ?Priority = null,
    signal: ?*AbortSignal = null,
};

pub fn postTask(self: *Scheduler, cb: js.Function.Global, options_: ?js.Value, exec: *js.Execution) !js.Promise {
    const local = exec.js.local.?;
    const resolver = local.createPromiseResolver();

    const opts: PostTaskOptions = blk: {
        const options_val = options_ orelse break :blk .{};
        if (options_val.isNullOrUndefined()) {
            break :blk .{};
        }
        break :blk options_val.toZig(PostTaskOptions) catch {
            cb.release();
            resolver.rejectError("scheduler.postTask", .{ .type_error = "invalid postTask options" });
            return resolver.promise();
        };
    };

    if (opts.signal) |signal| {
        if (signal._aborted) {
            cb.release();
            rejectWithReason(resolver, signal._reason, local);
            return resolver.promise();
        }
    }

    // An explicit priority wins over the signal's
    const priority: Priority = opts.priority orelse blk: {
        const signal = opts.signal orelse break :blk .@"user-visible";
        break :blk switch (signal._type) {
            .task_signal => |ts| ts._priority,
            .generic => .@"user-visible",
        };
    };

    const task = try Task.create(opts.signal, exec);
    task.cb = cb;
    task.scheduler = self;
    task.resolver = try resolver.persist();
    task.state = .{ .priority = priority, .signal = opts.signal };
    if (opts.signal) |signal| {
        try signal._dependents.append(exec.arena, .{ .scheduler_task = task });
    }
    try exec.js.scheduler.add(task, Task.run, opts.delay orelse 0, .{
        .name = "scheduler.postTask",
        .finalizer = Task.finalize,
    });
    return resolver.promise();
}

pub fn yield(self: *Scheduler, exec: *js.Execution) !js.Promise {
    const local = exec.js.local.?;
    const resolver = local.createPromiseResolver();

    const state = self._current orelse TaskState{ .priority = .@"user-visible", .signal = null };
    if (state.signal) |signal| {
        if (signal._aborted) {
            rejectWithReason(resolver, signal._reason, local);
            return resolver.promise();
        }
    }

    const task = try Task.create(state.signal, exec);
    task.cb = null;
    task.scheduler = self;
    task.resolver = try resolver.persist();
    task.state = state;
    if (state.signal) |signal| {
        try signal._dependents.append(exec.arena, .{ .scheduler_task = task });
    }
    try exec.js.scheduler.add(task, Task.run, 0, .{
        .name = "scheduler.yield",
        .front = true,
        .finalizer = Task.finalize,
    });
    return resolver.promise();
}

fn rejectWithReason(resolver: js.PromiseResolver, reason: AbortSignal.Reason, local: *const js.Local) void {
    const value = AbortSignal.reasonJsValue(reason, local) catch {
        resolver.rejectError("scheduler task abort", .{ .dom_exception = .{ .err = error.AbortError } });
        return;
    };
    resolver.reject("scheduler task abort", value);
}

pub const Task = struct {
    // null for a yield continuation
    cb: ?js.Function.Global,
    exec: *js.Execution,
    scheduler: *Scheduler,
    // null once settled (ran, aborted, or finalized)
    resolver: ?js.PromiseResolver.Global,
    state: TaskState,
    // Pooled backing arena, released when the queued task is consumed. null
    // when a signal is attached, the Task is pinned by the signal.
    arena: ?*lp.Arena,

    fn create(signal: ?*AbortSignal, exec: *js.Execution) !*Task {
        if (signal != null) {
            const task = try exec.arena.create(Task);
            task.exec = exec;
            task.arena = null;
            return task;
        }
        const arena = try exec.getArena(.tiny, "scheduler.task");
        const task = try arena.create(Task);
        task.exec = exec;
        task.arena = arena;
        return task;
    }

    fn deinit(self: *Task) void {
        if (self.resolver) |resolver| {
            resolver.release();
            self.resolver = null;
        }
        if (self.cb) |cb| {
            cb.release();
            self.cb = null;
        }
        if (self.arena) |arena| {
            self.arena = null;
            arena.release();
        }
    }

    fn finalize(ctx: *anyopaque) void {
        const self: *Task = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *Task = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        if (self.resolver == null) {
            return null; // onAbort fired
        }

        const prev = self.scheduler._current;
        self.scheduler._current = self.state;
        defer self.scheduler._current = prev;

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const cb_global = self.cb orelse {
            // yield continuation: the awaiting code runs in the microtasks
            // the resolve triggers, with _current set so it keeps inheriting.
            const resolver_global = self.resolver.?;
            self.resolver = null;
            defer resolver_global.release();
            ls.toLocal(resolver_global).resolve("scheduler.yield", {});
            return null;
        };

        self.cb = null;
        defer cb_global.release();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        // callback could still abort this...
        const call_result = ls.toLocal(cb_global).callRethrow(js.Value, .{});

        if (call_result) |result| {
            const resolver_global = self.resolver orelse return null;
            self.resolver = null;
            defer resolver_global.release();
            ls.toLocal(resolver_global).resolve("scheduler.postTask", result);
        } else |err| {
            if (err == error.ExecutionTerminated) {
                return err;
            }
            self.exec.page.recordJsError(err);

            const resolver_global = self.resolver orelse return null;
            self.resolver = null;
            defer resolver_global.release();

            const resolver = ls.toLocal(resolver_global);
            if (try_catch.exceptionValue()) |exception| {
                resolver.reject("scheduler.postTask", exception);
            } else {
                resolver.rejectError("scheduler.postTask", .{ .generic_error = "postTask callback failed" });
            }
        }
        return null;
    }

    // Called by AbortSignal when our signal aborts before the task ran. The task
    // will still run, but resolver will be null and it'll exit.
    pub fn onAbort(self: *Task, reason: AbortSignal.Reason, exec: *const Execution) void {
        const resolver_global = self.resolver orelse return;
        defer resolver_global.release();

        self.resolver = null;

        if (self.cb) |cb| {
            cb.release();
            self.cb = null;
        }

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        rejectWithReason(resolver_global.local(&ls.local), reason, &ls.local);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Scheduler);

    pub const Meta = struct {
        pub const name = "Scheduler";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const postTask = bridge.function(Scheduler.postTask, .{});
    pub const yield = bridge.function(Scheduler.yield, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Scheduler" {
    try testing.htmlRunner("scheduler/scheduler.html", .{});
}

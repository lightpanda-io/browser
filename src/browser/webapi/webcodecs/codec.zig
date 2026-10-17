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

// The state machine shared by AudioDecoder, VideoDecoder, AudioEncoder and
// VideoEncoder. We support no codec at all: every configuration that gets
// past validation fails "Check Configuration Support", so a configure()
// always ends, a task later, in the codec closing with a NotSupportedError.
// https://w3c.github.io/webcodecs/#codec-processing-model-section

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");

const Execution = js.Execution;

const log = lp.log;

pub const State = enum { unconfigured, configured, closed };

pub const Init = struct {
    @"error": js.Function.Global,
    output: js.Function.Global,
};

// `Owner` is the interface: it has a `_core: Core(Owner)` field, plus
// asEventTarget, acquireRef and releaseRef.
pub fn Core(comptime Owner: type) type {
    return struct {
        const Self = @This();

        exec: *Execution,
        state: State = .unconfigured,
        // [[decodeQueueSize]] / [[encodeQueueSize]]
        queue_size: u32 = 0,
        // decoders only
        key_chunk_required: bool = false,
        dequeue_event_scheduled: bool = false,
        // Bumped by every reset: a pending configure message from before it
        // has been dropped from the control queue.
        generation: u32 = 0,
        output: js.Function.Global,
        error_callback: js.Function.Global,
        // pending flush() promises
        flushes: std.ArrayList(js.PromiseResolver.Global) = .empty,

        pub fn init(callbacks: Init, exec: *Execution) Self {
            return .{
                .exec = exec,
                .output = callbacks.output,
                .error_callback = callbacks.@"error",
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.flushes.items) |flush_resolver| {
                flush_resolver.release();
            }
            self.output.release();
            self.error_callback.release();
        }

        fn owner(self: *Self) *Owner {
            return @fieldParentPtr("_core", self);
        }

        pub fn getState(self: *const Self) []const u8 {
            return @tagName(self.state);
        }

        // configure(), after the config was found valid.
        pub fn configure(self: *Self, comptime is_decoder: bool) !void {
            if (self.state == .closed) {
                return error.InvalidStateError;
            }
            self.state = .configured;
            if (is_decoder) {
                self.key_chunk_required = true;
            }
            try self.queueTask(.configure);
        }

        // The checks decode()/encode() make before enqueuing. The work itself
        // never happens: the configure message ahead of it closes the codec.
        pub fn enqueue(self: *Self) !void {
            if (self.state != .configured) {
                return error.InvalidStateError;
            }
            self.queue_size += 1;
        }

        // The promise belongs to the caller's realm, which needn't be the one
        // the codec was created in: hence `exec`, rather than `self.exec`.
        pub fn flush(self: *Self, comptime is_decoder: bool, exec: *const Execution) !js.Promise {
            const local = exec.js.local.?;
            if (self.state != .configured) {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
            }
            if (is_decoder) {
                self.key_chunk_required = true;
            }
            const resolver = local.createPromiseResolver();
            const global = try resolver.persist();
            errdefer global.release();
            try self.flushes.append(self.owner()._arena.allocator(), global);
            return resolver.promise();
        }

        pub fn reset(self: *Self) !void {
            return self.resetWith(error.AbortError);
        }

        pub fn close(self: *Self) !void {
            if (self.state == .closed) {
                return error.InvalidStateError;
            }
            self.closeWith(error.AbortError);
        }

        // "Reset"
        fn resetWith(self: *Self, exception: anyerror) !void {
            if (self.state == .closed) {
                return error.InvalidStateError;
            }
            self.state = .unconfigured;
            self.clearQueues();
            self.rejectFlushes(exception);
        }

        // "Close". In a browser, the flush promises' handlers only run once
        // the whole algorithm is done, after the error callback. Rejecting
        // runs them right away here, so the callback goes first.
        fn closeWith(self: *Self, exception: anyerror) void {
            self.state = .closed;
            self.clearQueues();
            if (exception != error.AbortError) {
                self.reportError(exception);
            }
            self.rejectFlushes(exception);
        }

        // Drops pending control messages and work.
        fn clearQueues(self: *Self) void {
            self.generation +%= 1;
            if (self.queue_size > 0) {
                self.queue_size = 0;
                self.queueTask(.dequeue) catch |err| {
                    log.warn(.js, "codec dequeue event", .{ .err = err });
                };
            }
        }

        fn rejectFlushes(self: *Self, exception: anyerror) void {
            if (self.flushes.items.len == 0) {
                return;
            }
            var ls: js.Local.Scope = undefined;
            self.exec.js.localScope(&ls);
            defer ls.deinit();

            // taken first: rejecting can't re-enter, but keep it simple
            const flushes = self.flushes.items;
            self.flushes = .empty;
            for (flushes) |global| {
                global.local(&ls.local).rejectError("codec flush", .{ .dom_exception = .{ .err = exception } });
                global.release();
            }
        }

        fn reportError(self: *Self, exception: anyerror) void {
            var ls: js.Local.Scope = undefined;
            self.exec.js.localScope(&ls);
            defer ls.deinit();

            const dom_exception = DOMException.fromError(exception) orelse return;
            ls.toLocal(self.error_callback).callWithThisReport(js.Undefined{}, .{dom_exception}) catch |err| {
                log.debug(.js, "codec error callback", .{ .err = err });
            };
        }

        const TaskKind = enum { configure, dequeue };

        const Task = struct {
            core: *Self,
            kind: TaskKind,
            generation: u32,

            fn run(ctx: *anyopaque) !?u32 {
                const task: *Task = @ptrCast(@alignCast(ctx));
                const core = task.core;
                const kind = task.kind;
                const generation = task.generation;
                const exec = core.exec;
                exec._factory.destroy(task);
                defer core.owner().releaseRef(exec.page);

                switch (kind) {
                    // "Check Configuration Support" says no.
                    .configure => if (generation == core.generation and core.state == .configured) {
                        core.closeWith(error.NotSupported);
                    },
                    .dequeue => {
                        core.dequeue_event_scheduled = false;
                        const event = try Event.initTrusted(comptime .wrap("dequeue"), .{}, exec.page);
                        try exec.dispatch(core.owner().asEventTarget(), event, .{ .context = "codec dequeue" });
                    },
                }
                return null;
            }

            fn cancelled(ctx: *anyopaque) void {
                const task: *Task = @ptrCast(@alignCast(ctx));
                const core = task.core;
                const exec = core.exec;
                exec._factory.destroy(task);
                core.owner().releaseRef(exec.page);
            }
        };

        fn queueTask(self: *Self, comptime kind: TaskKind) !void {
            if (kind == .dequeue) {
                if (self.dequeue_event_scheduled) return;
                self.dequeue_event_scheduled = true;
            }
            const exec = self.exec;
            const task = try exec._factory.create(Task{ .core = self, .kind = kind, .generation = self.generation });
            errdefer exec._factory.destroy(task);

            const o = self.owner();
            o.acquireRef();
            errdefer o.releaseRef(exec.page);

            try exec._scheduler.add(task, Task.run, 0, .{
                .name = "webcodecs." ++ @tagName(kind),
                .finalizer = Task.cancelled,
            });
        }
    };
}

// Codec strings never have surrounding whitespace once valid: " opus " is
// a valid config, but an unsupported one.
pub fn isEmptyCodec(codec: []const u8) bool {
    return std.mem.trim(u8, codec, &std.ascii.whitespace).len == 0;
}

// The [detached] check on a config's `description`.
pub fn isDetachedBuffer(value: js.Value) bool {
    const buffer = if (value.isArrayBufferView())
        (value.toObject().get("buffer") catch return false)
    else
        value;
    if (buffer.isArrayBuffer() == false) {
        return false;
    }
    const detached = buffer.toObject().get("detached") catch return false;
    return detached.isTrue();
}

// isConfigSupported(): its argument is converted by hand, so that an invalid
// dictionary rejects the promise rather than throwing.
pub fn isConfigSupported(comptime Config: type, value: js.Value, exec: *Execution) !js.Promise {
    const local = exec.js.local.?;
    const config = blk: {
        const parsed = value.toZig(?Config) catch break :blk null;
        break :blk parsed;
    } orelse return local.rejectPromise(.{ .type_error = "invalid configuration" });

    if (config.isValid() == false) {
        return local.rejectPromise(.{ .type_error = "invalid configuration" });
    }

    const result = local.newObject();
    _ = try result.set("supported", false, .{});
    _ = try result.set("config", try cloneConfig(local, config), .{});
    return local.resolvePromise(result);
}

// "Clone Configuration": the recognized members only, buffers copied.
fn cloneConfig(local: *const js.Local, config: anytype) !js.Object {
    const T = @TypeOf(config);
    const object = local.newObject();
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const value = @field(config, name);
        if (@typeInfo(@TypeOf(value)) == .optional) {
            if (value) |v| {
                try cloneMember(local, object, name, v);
            }
        } else {
            try cloneMember(local, object, name, value);
        }
    }
    return object;
}

fn cloneMember(local: *const js.Local, object: js.Object, comptime name: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == js.Value) {
        // description: an AllowSharedBufferSource
        const bytes = (try value.toZig(js.AllowSharedBufferSource)).bytes;
        _ = try object.set(name, js.ArrayBuffer{ .values = bytes }, .{});
    } else if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "js_enforce_range")) {
        _ = try object.set(name, value.value, .{});
    } else if (T != []const u8 and @typeInfo(T) == .@"struct") {
        _ = try object.set(name, try cloneConfig(local, value), .{});
    } else {
        _ = try object.set(name, value, .{});
    }
}

// Every enum-typed config member is taken as a string, and checked here.
pub fn checkEnum(value: []const u8, comptime allowed: []const []const u8) bool {
    inline for (allowed) |a| {
        if (std.mem.eql(u8, value, a)) return true;
    }
    return false;
}

pub const hardware_acceleration = &.{ "no-preference", "prefer-hardware", "prefer-software" };

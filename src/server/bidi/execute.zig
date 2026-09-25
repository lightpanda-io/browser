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

// Unlike most WebDriver endpoints, we can't re-use the BiDi flow here. The
// flow is too different. WebDriver treats throws as command failures and
// serializs over JSON. BiDi treats throws as success with the error reported
// inside and serializes via RemoteValue.

const std = @import("std");
const lp = @import("lightpanda");

const NodeRegistry = @import("../../NodeRegistry.zig");

const js = @import("../../browser/js/js.zig");
const Frame = @import("../../browser/Frame.zig");
const Node = @import("../../browser/webapi/Node.zig");
const NodeList = @import("../../browser/webapi/collections/NodeList.zig");
const HTMLCollection = @import("../../browser/webapi/collections/HTMLCollection.zig");

const BiDi = @import("BiDi.zig");
const http_command = @import("http_command.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const Script = struct {
    script: []const u8,
    args: []const std.json.Value = &.{},
};

pub const Mode = enum {
    sync,
    async,
};

// POST /session/{id}/execute/sync, POST /session/{id}/execute/async
pub fn run(cmd: *BiDi.Command, p: Script, mode: Mode) !void {
    const bidi = cmd.bidi;
    const frame = bidi.user_context.session.currentFrame() orelse {
        return cmd.sendError("no such window", "no frame");
    };

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    // `script` is a function *body*, not an expression
    const function = local.compileFunction(p.script, &.{}, &.{}) catch |err| {
        if (err == error.ExecutionTerminated or err == error.OutOfMemory) {
            return err;
        }
        return cmd.sendError("javascript error", exceptionText(cmd.arena, &try_catch, err));
    };

    const extra = @intFromBool(mode == .async);
    const arguments = try cmd.arena.alloc(js.Value, p.args.len + extra);
    for (p.args, arguments[0..p.args.len]) |argument, *js_argument| {
        js_argument.* = fromJson(local, &bidi.node_registry, argument, frame) catch |err| switch (err) {
            error.NoSuchElement => return cmd.sendError("no such element", "unknown element reference"),
            error.StaleElement => return cmd.sendError("stale element reference", "element is not in the current document"),
            error.InvalidArgument => return cmd.sendError("invalid argument", "cannot deserialize an argument"),
            else => return err,
        };
    }

    var deferred: ?js.Promise = null;
    if (mode == .async) {
        // It looks like we're supposed to give it a plain callback (which we
        // could, via `local.newCallback`), but a promise makes managing the
        // lifetime easier (because it can only be settled once).
        const pair = (try local.exec(async_bridge, "webdriver.executeAsync")).toArray();
        deferred = (try pair.get(0)).toPromise();
        arguments[p.args.len] = try pair.get(1);
    }

    const undef = try local.zigValueToJs({}, .{});
    const returned = function.callWithThisRethrow(js.Value, undef, arguments) catch |err| {
        if (err == error.ExecutionTerminated or err == error.OutOfMemory) {
            return err;
        }
        return cmd.sendError("javascript error", exceptionText(cmd.arena, &try_catch, err));
    };

    // An async script's return value is ignored, the resolved value is what answers.
    const value = if (deferred) |promise| promise.toValue() else returned;
    if (value.isPromise() == false) {
        return sendResult(cmd, frame, local, value);
    }

    // this isn't jus the async path, we're also here if the sync script returned
    // a promise. This is another advantage of using a profile as our async
    // paramater: it gives us a single thing to handle here (a promise) rather
    // than a promise (from a sync return) and a callback (if we used local.newCallback)

    const promise = value.toPromise();
    promise.markAsHandled();
    local.runMicrotasks();

    switch (promise.state()) {
        .fulfilled => return sendResult(cmd, frame, local, promise.result()),
        .rejected => return sendRejection(cmd, promise.result()),
        .pending => {
            const pnd = try Pending.create(cmd, frame);
            _ = try promise.thenAndCatch(
                local.newCallback(Pending.onFulfilled, pnd),
                local.newCallback(Pending.onRejected, pnd),
            );
        },
    }
}

// Returns [promise, resolve]. The script gets `resolve`; we wait on the promise.
const async_bridge = "(function(){var r; var p = new Promise(function(res){r = res;}); return [p, r];})()";

fn sendResult(cmd: *BiDi.Command, frame: *Frame, local: *const js.Local, value: js.Value) !void {
    const cloned = clone(cmd.arena, &cmd.bidi.node_registry, frame, local, value) catch |err| switch (err) {
        error.OutOfMemory, error.ExecutionTerminated => return err,
        else => return cmd.sendError("javascript error", cloneErrorMessage(err)),
    };
    return cmd.sendResult(cloned);
}

fn sendRejection(cmd: *BiDi.Command, reason: js.Value) !void {
    return cmd.sendError("javascript error", rejectionText(cmd.arena, reason));
}

// The exception stringified ("Error: nope"), not just its message, which is
// what a driver's users expect to read.
fn exceptionText(arena: Allocator, try_catch: *const js.TryCatch, err: anyerror) []const u8 {
    const caught = try_catch.caughtOrError(arena, err);
    const fallback = caught.exception orelse @errorName(err);
    const thrown = try_catch.exceptionValue() orelse return fallback;
    return thrown.toStringSliceWithAlloc(arena) catch fallback;
}

fn rejectionText(arena: Allocator, reason: js.Value) []const u8 {
    return reason.toStringSliceWithAlloc(arena) catch "promise rejected";
}

// Script with a value that'll come later, i.e. a sync script that returned
// a promise (thus, when the promise is resolved/rejected) or for an async
// script that will resolve the promise.
pub const Pending = struct {
    bidi: *BiDi,
    to: BiDi.Reply,
    js_context_id: usize,
    deadline: ?u64, // null if there isn't one
    answered: bool = false,

    fn create(cmd: *BiDi.Command, frame: *Frame) !*Pending {
        const bidi = cmd.bidi;
        const allocator = bidi.app.allocator;
        const timeout = bidi.timeouts.script;

        const self = try allocator.create(Pending);
        errdefer allocator.destroy(self);

        self.* = .{
            .bidi = bidi,
            .to = cmd.reply(),
            .js_context_id = frame.js.id,
            .deadline = if (timeout) |ms| lp.datetime.milliTimestamp(.boot) + ms else null,
        };
        try bidi.execute_pending.append(allocator, self);
        errdefer _ = bidi.execute_pending.pop();

        if (timeout) |ms| {
            // timeout defaults to 30 seconds and is likely not going to be
            // needed, never block done for this.
            try frame.js.scheduler.add(bidi, onTimeout, ms, .{
                .name = "webdriver.scriptTimeout",
                .blocks_done = false,
            });
        }

        // from this point on, we own the reply
        _ = cmd.takeReply();
        return self;
    }

    fn unregister(self: *Pending) void {
        const bidi = self.bidi;
        for (bidi.execute_pending.items, 0..) |pending, i| {
            if (pending == self) {
                _ = bidi.execute_pending.swapRemove(i);
                break;
            }
        }
        bidi.app.allocator.destroy(self);
    }

    fn onFulfilled(self: *Pending, value: js.Value, exec: *const js.Execution) void {
        defer self.unregister();
        self.answer(exec.js.local.?, value);
    }

    fn onRejected(self: *Pending, reason: js.Value, _: *const js.Execution) void {
        defer self.unregister();
        if (self.answered) {
            return;
        }
        const arena = self.scratch() orelse return;
        defer arena.release();
        self.fail("javascript error", rejectionText(arena.allocator(), reason));
    }

    // The ctx for this is *BiDi, not *Pending, because the *Pending will clean
    // itself up once the promise is resolved/rejected, but the scheduled timeout
    // will live on. To make this work with a *Pending, the Scheduler would need
    // to be able to remove a task. Don't think we've needed that before, and
    // hard to justify just for this case. So, what we can do it just scan
    // the bidi's list of pending's to see if any have timed out.
    fn onTimeout(ctx: *anyopaque) !?u32 {
        // Ab
        const bidi: *BiDi = @ptrCast(@alignCast(ctx));
        const now = lp.datetime.milliTimestamp(.boot);

        var soonest: ?u64 = null;
        var i = bidi.execute_pending.items.len;
        while (i > 0) {
            i -= 1;
            const pending = bidi.execute_pending.items[i];
            const deadline = pending.deadline orelse continue;
            if (deadline > now) {
                soonest = if (soonest) |s| @min(s, deadline) else deadline;
                continue;
            }
            // Most important thing is here: we answer but don't free. The
            // promise could still be resolved at some point in the future!
            pending.fail("script timeout", "the script did not complete within the script timeout");
            pending.deadline = null;
        }

        if (soonest) |deadline| {
            return @intCast(deadline - now);
        }
        return null;
    }

    fn answer(self: *Pending, local: *const js.Local, value: js.Value) void {
        if (self.answered) {
            return;
        }

        const bidi = self.bidi;
        const frame = bidi.user_context.session.currentFrame() orelse {
            return self.fail("no such window", "no frame");
        };

        const arena = self.scratch() orelse return;
        defer arena.release();

        const cloned = clone(arena.allocator(), &bidi.node_registry, frame, local, value) catch |err| {
            return self.fail("javascript error", cloneErrorMessage(err));
        };

        self.answered = true;
        bidi.replyResult(self.to, cloned) catch |err| {
            log.err(.bidi, "execute result", .{ .err = err, .reply = self.to });
        };
    }

    fn fail(self: *Pending, code: []const u8, message: []const u8) void {
        if (self.answered) {
            return;
        }
        self.answered = true;
        self.bidi.replyError(self.to, code, message) catch |err| {
            log.err(.bidi, "execute error", .{ .err = err, .reply = self.to });
        };
    }

    fn scratch(self: *Pending) ?*lp.Arena {
        return self.bidi.app.arena_pool.acquire(.small, "webdriver execute") catch |err| {
            self.fail("unknown error", @errorName(err));
            return null;
        };
    }

    pub fn realmReset(bidi: *BiDi) void {
        for (bidi.execute_pending.items) |pending| {
            pending.fail("javascript error", "the document was unloaded while the script was running");
        }
    }

    // A frame, and with it the JS context holding our callbacks, is gone.
    pub fn contextDestroyed(bidi: *BiDi, js_context_id: usize) void {
        var i = bidi.execute_pending.items.len;
        while (i > 0) {
            i -= 1;
            const pending = bidi.execute_pending.items[i];
            if (pending.js_context_id == js_context_id) {
                _ = bidi.execute_pending.swapRemove(i);
                bidi.app.allocator.destroy(pending);
            }
        }
    }

    // Teardown: completions are still reachable, but their reply isn't.
    pub fn cancelAll(bidi: *BiDi) void {
        for (bidi.execute_pending.items) |pending| {
            pending.answered = true;
        }
    }

    pub fn destroyAll(bidi: *BiDi) void {
        while (bidi.execute_pending.pop()) |pending| {
            bidi.app.allocator.destroy(pending);
        }
    }
};

const CloneError = error{
    CyclicReference,
    TooDeep,
    OutOfMemory,
    ExecutionTerminated,
    TypeError,
    JsException,
    MethodNotFound,
    DeadFunctionHandle,
    InvalidArgument,
};

fn cloneErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.CyclicReference => "cannot serialize a circular reference",
        error.TooDeep => "the result is nested too deeply to serialize",
        else => "cannot serialize the script's result",
    };
}

// W3C's "JSON clone" of a script's result. Not a RemoteValue: a client reads
// it as plain JSON, with an element the one exception.
const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    element: http_command.Reference,
    array: []const Value,
    object: []const Property,

    pub const Property = struct {
        name: []const u8,
        value: Value,
    };

    pub fn jsonStringify(self: *const Value, w: anytype) !void {
        switch (self.*) {
            .null => try w.write(null),
            .boolean => |v| try w.write(v),
            .string => |v| try w.write(v),
            .element => |v| try w.write(v),
            .number => |v| {
                // JSON has no NaN or Infinity, and a whole number must not go
                // out as 3e0 -- a client that rejects non-conforming JSON is
                // within its rights.
                if (std.math.isFinite(v) == false) {
                    return w.write(null);
                }
                const max_safe_integer = 9007199254740991;
                if (@trunc(v) == v and @abs(v) <= max_safe_integer) {
                    return w.write(@as(i64, @intFromFloat(v)));
                }
                try w.write(v);
            },
            .array => |values| {
                try w.beginArray();
                for (values) |*value| {
                    try w.write(value);
                }
                try w.endArray();
            },
            .object => |properties| {
                try w.beginObject();
                for (properties) |*property| {
                    try w.objectField(property.name);
                    try w.write(&property.value);
                }
                try w.endObject();
            },
        }
    }
};

fn clone(
    arena: Allocator,
    registry: *NodeRegistry,
    frame: *Frame,
    local: *const js.Local,
    value: js.Value,
) CloneError!Value {
    var cloner: Cloner = .{ .arena = arena, .registry = registry, .frame = frame, .local = local };
    return cloner.run(value);
}

const Cloner = struct {
    arena: Allocator,
    registry: *NodeRegistry,
    frame: *Frame,
    local: *const js.Local,
    // cyclical dependencies are an error (vs RemoteValue which collapses it)
    seen: std.ArrayList(js.Object) = .empty, //cyclicli

    const max_depth = 64;

    fn run(self: *Cloner, value: js.Value) CloneError!Value {
        if (value.isNullOrUndefined()) {
            return .null;
        }
        if (value.isBoolean()) {
            return .{ .boolean = value.toBool() };
        }
        if (value.isNumber()) {
            return .{ .number = try value.toF64() };
        }
        if (value.isString() != null) {
            return .{ .string = try value.toStringSliceWithAlloc(self.arena) };
        }
        if (value.isObject() == false) {
            // a symbol or a bigint
            return .null;
        }

        const object = value.toObject();
        if (self.isSeen(object)) {
            return error.CyclicReference;
        }
        if (self.seen.items.len == max_depth) {
            return error.TooDeep;
        }
        try self.seen.append(self.arena, object);
        defer _ = self.seen.pop();

        if (value.taggedOpaque()) |tao| {
            if (try self.platform(tao)) |cloned| {
                return cloned;
            }
            // self.platform() only handles a few select types. Everything else
            // goes through a more generic path , e.g. self.properties()
        }

        if (value.isArray()) {
            return .{ .array = try self.items(value.toArray()) };
        }

        if (try object.getFunction("toJSON") != null) {
            return self.run(try object.callMethod(js.Value, "toJSON", .{}));
        }

        return .{ .object = try self.properties(object) };
    }

    fn platform(self: *Cloner, tao: *const js.TaggedOpaque) !?Value {
        if (tao.as(Node)) |node| {
            // Non-elements will be serialized via properties()
            const element = node.is(Node.Element) orelse return null;
            return .{ .element = try self.reference(element.asNode()) };
        }

        if (tao.as(NodeList)) |list| {
            const values = try self.arena.alloc(Value, try list.length(self.frame));
            for (values, 0..) |*item, i| {
                const node = (try list.getAtIndex(i, self.frame)) orelse unreachable;
                item.* = try self.run(try self.local.zigValueToJs(node, .{}));
            }
            return .{ .array = values };
        }

        if (tao.as(HTMLCollection)) |collection| {
            const values = try self.arena.alloc(Value, collection.length(self.frame));
            for (values, 0..) |*item, i| {
                const element = collection.getAtIndex(i, self.frame) orelse unreachable;
                item.* = .{ .element = try self.reference(element.asNode()) };
            }
            return .{ .array = values };
        }

        return null;
    }

    fn reference(self: *Cloner, node: *Node) !http_command.Reference {
        return .init(self.arena, self.registry, node);
    }

    fn items(self: *Cloner, array: js.Array) CloneError![]const Value {
        const values = try self.arena.alloc(Value, array.len());
        for (values, 0..) |*value, i| {
            value.* = try self.run(try array.get(@intCast(i)));
        }
        return values;
    }

    fn properties(self: *Cloner, object: js.Object) CloneError![]const Value.Property {
        var it = try object.iterator();
        var list: std.ArrayList(Value.Property) = try .initCapacity(self.arena, it.count);
        while (try it.next()) |entry| {
            list.appendAssumeCapacity(.{
                .name = try self.arena.dupe(u8, entry.name),
                .value = try self.run(entry.value),
            });
        }
        return list.items;
    }

    fn isSeen(self: *const Cloner, object: js.Object) bool {
        const candidate = object.toValue();
        for (self.seen.items) |ancestor| {
            if (ancestor.toValue().strictEquals(candidate)) {
                return true;
            }
        }
        return false;
    }
};

fn fromJson(
    local: *const js.Local,
    registry: *const NodeRegistry,
    value: std.json.Value,
    frame: *const Frame,
) !js.Value {
    switch (value) {
        .null => return local.zigValueToJs(null, .{}),
        .bool => |v| return local.zigValueToJs(v, .{}),
        .integer => |v| return local.newNumber(@floatFromInt(v)),
        .float => |v| return local.newNumber(v),
        .number_string => |v| return local.newNumber(std.fmt.parseFloat(f64, v) catch return error.InvalidArgument),
        .string => |v| return local.zigValueToJs(v, .{}),
        .array => |v| {
            var array = local.newArray(@intCast(v.items.len));
            for (v.items, 0..) |item, i| {
                if (try array.set(@intCast(i), try fromJson(local, registry, item, frame), .{}) == false) {
                    return error.InvalidArgument;
                }
            }
            return array.toValue();
        },
        .object => |fields| {
            if (fields.get(http_command.element_key)) |id| {
                const shared_id = switch (id) {
                    .string => |s| s,
                    else => return error.NoSuchElement,
                };
                const element = try http_command.elementFromReference(registry, shared_id, frame);
                return local.zigValueToJs(element.asNode(), .{});
            }

            const object = local.newObject();
            var it = fields.iterator();
            while (it.next()) |entry| {
                const item = try fromJson(local, registry, entry.value_ptr.*, frame);
                if (try object.set(entry.key_ptr.*, item, .{}) == false) {
                    return error.InvalidArgument;
                }
            }
            return object.toValue();
        },
    }
}

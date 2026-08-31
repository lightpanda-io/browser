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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../browser/js/js.zig");
const Frame = @import("../../browser/Frame.zig");

const BiDi = @import("BiDi.zig");
const remote_value = @import("remote_value.zig");
const browsing_context = @import("browsing_context.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *const BiDi.Command) !void {
    const command = std.meta.stringToEnum(enum {
        evaluate,
        callFunction,
        disown,
    }, cmd.action) orelse return error.UnknownCommand;

    switch (command) {
        .evaluate => return evaluate(cmd),
        .callFunction => return callFunction(cmd),
        .disown => return disown(cmd),
    }
}

// Addresses the realm to run in. We only have the one, so a `realm` is
// accepted but a `sandbox` isn't.
const Target = struct {
    context: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
};

const ResultOwnership = enum { root, none };

fn evaluate(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        expression: []const u8,
        target: Target,
        awaitPromise: bool = false,
        resultOwnership: ResultOwnership = .none,
        serializationOptions: remote_value.SerializationOptions = .{},
        userActivation: bool = false,
    });

    const ctx = (try resolveTarget(cmd, p.target)) orelse return;
    const frame = cmd.bidi.user_context.session.currentFrame() orelse {
        return cmd.sendError("no such frame", "no frame");
    };

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const reply: Reply = .init(cmd, ctx);
    const value = ls.local.exec(p.expression, "bidi.evaluate") catch |err| {
        return sendException(&reply, frame, &ls.local, &try_catch, err);
    };

    return settle(&reply, frame, &ls.local, value, p.awaitPromise, p.serializationOptions.options(p.resultOwnership == .root));
}

fn callFunction(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        functionDeclaration: []const u8,
        target: Target,
        awaitPromise: bool = false,
        arguments: []const std.json.Value = &.{},
        this: ?std.json.Value = null,
        resultOwnership: ResultOwnership = .none,
        serializationOptions: remote_value.SerializationOptions = .{},
        userActivation: bool = false,
    });

    const bidi = cmd.bidi;
    const ctx = (try resolveTarget(cmd, p.target)) orelse return;
    const frame = bidi.user_context.session.currentFrame() orelse {
        return cmd.sendError("no such frame", "no frame");
    };

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // functionDeclaration is a function *expression*. Evaluating it
    // parenthesized is what turns it into something callable. \n added incase
    // the functionDeclaration has a trailing comment.
    const arena = cmd.arena;
    const source = try std.fmt.allocPrint(arena, "({s}\n)", .{p.functionDeclaration});
    const reply: Reply = .init(cmd, ctx);
    const declaration = ls.local.exec(source, "bidi.callFunction") catch |err| {
        return sendException(&reply, frame, &ls.local, &try_catch, err);
    };
    if (declaration.isFunction() == false) {
        return cmd.sendError("invalid argument", "functionDeclaration is not a function");
    }
    const function = js.Function{ .local = &ls.local, .handle = @ptrCast(declaration.handle) };

    const arguments = try arena.alloc(js.Value, p.arguments.len);
    for (p.arguments, arguments) |argument, *js_argument| {
        js_argument.* = (try toJs(cmd, &ls.local, argument)) orelse return;
    }

    // `this` should be undefined when not given
    const this = if (p.this) |t| ((try toJs(cmd, &ls.local, t)) orelse return) else try ls.local.zigValueToJs({}, .{});

    const value = function.callWithThisRethrow(js.Value, this, arguments) catch |err| {
        return sendException(&reply, frame, &ls.local, &try_catch, err);
    };

    return settle(&reply, frame, &ls.local, value, p.awaitPromise, p.serializationOptions.options(p.resultOwnership == .root));
}

fn disown(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        handles: []const []const u8,
        target: Target,
    });

    if ((try resolveTarget(cmd, p.target)) == null) {
        return;
    }

    // Unknown handles are not an error, just ignore them.
    for (p.handles) |handle| {
        const id = std.fmt.parseInt(u32, handle, 10) catch continue;
        cmd.bidi.handles.release(id);
    }

    return cmd.sendResult(struct {}{});
}

// What answering a command takes, so the same code serves both an immediate
// reply and one sent from a promise callback after the Command (and its
// message_arena) is gone.
const Reply = struct {
    id: u64,
    bidi: *BiDi,
    arena: Allocator,
    realm_id: [36]u8,

    fn init(cmd: *const BiDi.Command, ctx: *const browsing_context.Context) Reply {
        return .{
            .id = cmd.id,
            .bidi = cmd.bidi,
            .arena = cmd.arena,
            .realm_id = ctx.realm_id,
        };
    }

    fn sendResult(self: *const Reply, result: anytype) !void {
        return self.bidi.sendResult(self.id, result);
    }

    fn sendError(self: *const Reply, code: []const u8, message: []const u8) !void {
        return self.bidi.sendError(self.id, code, message);
    }
};

// Answers with an EvaluateResultSuccess, resolving the promise first if the
// client asked for it.
fn settle(
    reply: *const Reply,
    frame: *Frame,
    local: *const js.Local,
    value: js.Value,
    await_promise: bool,
    opts: remote_value.Serializer.Options,
) !void {
    var result = value;

    if (await_promise and value.isPromise()) {
        const promise = value.toPromise();
        promise.markAsHandled();

        // some promises can be settled immediately.
        local.runMicrotasks();

        switch (promise.state()) {
            .fulfilled => result = promise.result(),
            .pending => return Pending.await(reply, promise, opts),
            .rejected => return sendRejection(reply, frame, local, promise.result()),
        }
    }

    const remote = (try serialize(reply, frame, local, result, opts)) orelse return;
    return reply.sendResult(.{
        .type = "success",
        .result = remote,
        .realm = &reply.realm_id,
    });
}

// A script command waiting a promise resolution.
pub const Pending = struct {
    reply: Reply,
    arena: *lp.Arena,
    js_context_id: usize,
    cancelled: bool = false,
    opts: remote_value.Serializer.Options,

    fn await(reply: *const Reply, promise: js.Promise, opts: remote_value.Serializer.Options) !void {
        const bidi = reply.bidi;
        const arena = try bidi.app.arena_pool.acquire(.small, "bidi Pending");
        errdefer arena.release();

        const pending = try arena.allocator().create(Pending);
        pending.* = .{
            .opts = opts,
            .arena = arena,
            .js_context_id = promise.local.ctx.id,
            .reply = .{ // clone reply, injecting our Pending's arena
                .id = reply.id,
                .bidi = reply.bidi,
                .arena = arena.allocator(),
                .realm_id = reply.realm_id,
            },
        };
        try bidi.pending.append(bidi.app.allocator, pending);
        errdefer _ = bidi.pending.pop();

        const local = promise.local;
        _ = try promise.thenAndCatch(
            local.newCallback(onFulfilled, pending),
            local.newCallback(onRejected, pending),
        );
    }

    fn deinit(self: *Pending) void {
        self.arena.release();
    }

    fn onFulfilled(self: *Pending, value: js.Value, exec: *const js.Execution) void {
        self.finish(value, .fulfilled, exec);
    }

    fn onRejected(self: *Pending, reason: js.Value, exec: *const js.Execution) void {
        self.finish(reason, .rejected, exec);
    }

    fn finish(
        self: *Pending,
        value: js.Value,
        state: enum { fulfilled, rejected },
        exec: *const js.Execution,
    ) void {
        defer self.destroy();
        if (self.cancelled) {
            return;
        }

        const reply = &self.reply;
        const local = exec.js.local.?;
        const frame = reply.bidi.user_context.session.currentFrame() orelse {
            reply.sendError("no such frame", "no frame") catch {};
            return;
        };

        const result = switch (state) {
            .fulfilled => settle(reply, frame, local, value, false, self.opts),
            .rejected => sendRejection(reply, frame, local, value),
        };

        result catch |err| {
            log.err(.bidi, "await promise", .{ .err = err, .id = reply.id });
        };
    }

    fn destroy(self: *Pending) void {
        const bidi = self.reply.bidi;
        for (bidi.pending.items, 0..) |pending, i| {
            if (pending == self) {
                _ = bidi.pending.swapRemove(i);
                break;
            }
        }
        self.deinit();
    }

    // The realm is being replaced: answer the client now. The Pending remains
    // alive until it fires or Frame.deinit -> ... -> contextDestroyed is called
    pub fn realmReset(bidi: *BiDi) void {
        for (bidi.pending.items) |pending| {
            if (pending.cancelled) {
                continue;
            }
            pending.cancelled = true;
            pending.reply.sendError("no such realm", "realm destroyed while awaiting a promise") catch {};
        }
    }

    // A frame (and it's JS context) is being destroyed.
    pub fn contextDestroyed(bidi: *BiDi, js_context_id: usize) void {
        var i = bidi.pending.items.len;
        while (i > 0) {
            i -= 1;
            const pending = bidi.pending.items[i];
            if (pending.js_context_id == js_context_id) {
                _ = bidi.pending.swapRemove(i);
                pending.deinit();
            }
        }
    }

    pub fn cancelAll(bidi: *BiDi) void {
        for (bidi.pending.items) |pending| {
            pending.cancelled = true;
        }
    }

    pub fn destroyAll(bidi: *BiDi) void {
        while (bidi.pending.pop()) |pending| {
            pending.deinit();
        }
    }
};

// A JS throw isn't a command failure: the command succeeds and reports the
// exception in its result. The thrown value is always serialized with the
// default options rather than the command's
fn sendException(
    reply: *const Reply,
    frame: *Frame,
    local: *const js.Local,
    try_catch: *js.TryCatch,
    err: anyerror,
) !void {
    if (err == error.ExecutionTerminated or err == error.OutOfMemory) {
        return err;
    }

    const arena = reply.arena;
    const caught = try_catch.caughtOrError(arena, err);

    const thrown = try_catch.exceptionValue();
    const exception: remote_value.Remote = blk: {
        const value = thrown orelse break :blk .{ .body = .undefined };
        break :blk (try serialize(reply, frame, local, value, .{})) orelse return;
    };

    // `text` is the exception stringified ("Error: nope"), not just its message
    const fallback = caught.exception orelse @errorName(err);
    const text = blk: {
        const value = thrown orelse break :blk fallback;
        break :blk value.toStringSliceWithAlloc(arena) catch fallback;
    };

    return sendExceptionDetails(reply, exception, text, caught.line);
}

fn sendRejection(
    reply: *const Reply,
    frame: *Frame,
    local: *const js.Local,
    reason: js.Value,
) !void {
    const text = reason.toStringSliceWithAlloc(reply.arena) catch "promise rejected";
    const exception = (try serialize(reply, frame, local, reason, .{})) orelse return;
    return sendExceptionDetails(reply, exception, text, null);
}

fn sendExceptionDetails(
    reply: *const Reply,
    exception: remote_value.Remote,
    text: []const u8,
    line: ?u32,
) !void {
    return reply.sendResult(.{
        .type = "exception",
        .exceptionDetails = .{
            .text = text,
            .exception = exception,
            .lineNumber = line orelse 0, // required by the spec, even if we don't know it
            .columnNumber = 0, // required by the spec, even if we don't know it
            .stackTrace = .{ .callFrames = &[_]struct {}{} },
        },
        .realm = &reply.realm_id,
    });
}

fn serialize(
    reply: *const Reply,
    frame: *Frame,
    local: *const js.Local,
    value: js.Value,
    opts: remote_value.Serializer.Options,
) !?remote_value.Remote {
    var serializer = remote_value.Serializer.init(reply.bidi, reply.arena, frame, local, opts);

    return serializer.run(value) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        log.warn(.bidi, "serialize", .{ .err = err });
        try reply.sendError("unknown error", "cannot serialize result");
        return null;
    };
}

// returns null when an error response was already sent.
fn toJs(cmd: *const BiDi.Command, local: *const js.Local, value: std.json.Value) !?js.Value {
    const bidi = cmd.bidi;
    return remote_value.toJs(local, &bidi.handles, &bidi.node_registry, value) catch |err| switch (err) {
        error.NoSuchHandle => {
            try cmd.sendError("no such handle", "unknown handle");
            return null;
        },
        error.NoSuchNode => {
            try cmd.sendError("no such node", "unknown sharedId");
            return null;
        },
        error.UnsupportedLocalValue => {
            try cmd.sendError("unsupported operation", "unsupported argument");
            return null;
        },
        else => return err,
    };
}

// Answers the client and returns null when the target doesn't name our one
// context, so callers can `orelse return`.
fn resolveTarget(cmd: *const BiDi.Command, target: Target) !?*browsing_context.Context {
    if (target.sandbox != null) {
        try cmd.sendError("unsupported operation", "sandboxes are not supported");
        return null;
    }

    const bidi = cmd.bidi;
    if (target.context) |context| {
        return browsing_context.requireContext(cmd, context);
    }

    if (target.realm) |realm| {
        if (bidi.browsing_context) |*ctx| {
            if (std.mem.eql(u8, &ctx.realm_id, realm)) {
                return ctx;
            }
        }
        try cmd.sendError("no such frame", "unknown realm");
        return null;
    }

    try cmd.sendError("invalid argument", "target requires a context or a realm");
    return null;
}

const testing = @import("testing.zig");

test "bidi.script: evaluate primitives" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    const cases = [_]struct { expression: []const u8, expected: []const u8 }{
        .{ .expression = "'hi'", .expected =
        \\{"type": "string", "value": "hi"}
        },
        .{ .expression = "1 + 2", .expected =
        \\{"type": "number", "value": 3}
        },
        // A whole number must not go out as 3e0 -- clients that reject
        // non-conforming JSON are within their rights.
        .{ .expression = "1.5", .expected =
        \\{"type": "number", "value": 1.5}
        },
        .{ .expression = "0/0", .expected =
        \\{"type": "number", "value": "NaN"}
        },
        .{ .expression = "-1/0", .expected =
        \\{"type": "number", "value": "-Infinity"}
        },
        .{ .expression = "-0", .expected =
        \\{"type": "number", "value": "-0"}
        },
        .{ .expression = "true", .expected =
        \\{"type": "boolean", "value": true}
        },
        .{ .expression = "null", .expected =
        \\{"type": "null"}
        },
        .{ .expression = "undefined", .expected =
        \\{"type": "undefined"}
        },
        .{ .expression = "12345678901234567890n", .expected =
        \\{"type": "bigint", "value": "12345678901234567890"}
        },
        .{ .expression = "() => {}", .expected =
        \\{"type": "function"}
        },
        .{ .expression = "new Map()", .expected =
        \\{"type": "map"}
        },
        .{ .expression = "new Set()", .expected =
        \\{"type": "set"}
        },
        .{ .expression = "new WeakMap()", .expected =
        \\{"type": "weakmap"}
        },
        .{ .expression = "new WeakSet()", .expected =
        \\{"type": "weakset"}
        },
        // A proxy is reported as a proxy, not as its target.
        .{ .expression = "new Proxy(new Map(), {})", .expected =
        \\{"type": "proxy"}
        },
        .{ .expression = "(function*(){})()", .expected =
        \\{"type": "generator"}
        },
        .{ .expression = "/ab+c/gi", .expected =
        \\{"type": "regexp", "value": {"pattern": "ab+c", "flags": "gi"}}
        },
        .{ .expression = "new Date(0)", .expected =
        \\{"type": "date", "value": "1970-01-01T00:00:00.000Z"}
        },
        .{ .expression = "new Date(1755264000123)", .expected =
        \\{"type": "date", "value": "2025-08-15T13:20:00.123Z"}
        },
        // Past year 9999 JS switches to a six-digit year.
        .{ .expression = "new Date(8.64e15)", .expected =
        \\{"type": "date", "value": "+275760-09-13T00:00:00.000Z"}
        },
        // toISOString would throw; String() round-trips on the client.
        .{ .expression = "new Date(NaN)", .expected =
        \\{"type": "date", "value": "Invalid Date"}
        },
        .{ .expression = "window", .expected =
        \\{"type": "window"}
        },
    };

    for (cases, 0..) |case, i| {
        const id = i + 1;
        try ctx.processMessage(.{
            .id = id,
            .method = "script.evaluate",
            .params = .{
                .expression = case.expression,
                .target = .{ .context = context_id },
                .awaitPromise = false,
            },
        });
        try ctx.expectSentResult(.{
            .type = "success",
            .result = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena, case.expected, .{}),
        }, .{ .id = id });
    }
}

test "bidi.script: evaluate arrays and objects" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "[1, 'two', {a: [true]}]",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{
            .type = "array",
            .value = .{
                .{ .type = "number", .value = 1 },
                .{ .type = "string", .value = "two" },
                .{
                    .type = "object",
                    .value = .{
                        .{ "a", .{ .type = "array", .value = .{.{ .type = "boolean", .value = true }} } },
                    },
                },
            },
        },
    }, .{ .id = 1 });

    // maxObjectDepth 0 is how a driver asks for a reference without paying
    // for the contents; the value is omitted entirely.
    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{
            .expression = "({a: 1})",
            .target = .{ .context = context_id },
            .serializationOptions = .{ .maxObjectDepth = 0 },
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "object" } }, .{ .id = 2 });

    // A self-reference collapses to the bare type rather than recursing:
    // maxObjectDepth defaults to unlimited.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "(() => { const a = {}; a.self = a; return a; })()",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "object", .value = .{.{ "self", .{ .type = "object" } }} },
    }, .{ .id = 3 });
}

test "bidi.script: serialization survives a page tampering with its globals" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "delete Object.prototype.toString; delete window.Set; Date.prototype.toISOString = () => 'nope'; 1",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{ .type = "success" }, .{ .id = 1 });

    // Nothing in serialization goes through the page's globals, cycle guard
    // included.
    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{
            .expression = "(() => { const a = {n: 1}; a.self = a; return [a, a]; })()",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{
            .type = "array",
            .value = .{
                // The repeat inside `a` is the cycle; the second element is
                // only a shared reference, so it serializes in full.
                .{ .type = "object", .value = .{
                    .{ "n", .{ .type = "number", .value = 1 } },
                    .{ "self", .{ .type = "object" } },
                } },
                .{ .type = "object", .value = .{
                    .{ "n", .{ .type = "number", .value = 1 } },
                    .{ "self", .{ .type = "object" } },
                } },
            },
        },
    }, .{ .id = 2 });

    // The native predicates still recognize a Map, deleted Set (and deleted
    // Object.prototype.toString) notwithstanding.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "new Map()",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "map" } }, .{ .id = 3 });

    // A date is formatted natively, not through Date.prototype.
    try ctx.processMessage(.{
        .id = 5,
        .method = "script.evaluate",
        .params = .{
            .expression = "new Date(0)",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "date", .value = "1970-01-01T00:00:00.000Z" },
    }, .{ .id = 5 });

    // A custom class has no bare-type name; it serializes as a plain object.
    try ctx.processMessage(.{
        .id = 4,
        .method = "script.evaluate",
        .params = .{
            .expression = "new (function Fake(){})()",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "object" } }, .{ .id = 4 });
}

test "bidi.script: evaluate nodes" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    // maxDomDepth defaults to 0: the node's own properties, no children.
    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "document.getElementById('main')",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{
            .type = "node",
            .sharedId = "1",
            .value = .{
                .nodeType = 1,
                .childNodeCount = 1,
                .localName = "div",
                .attributes = .{ .id = "main", .class = "a b", .@"data-x" = "1" },
            },
        },
    }, .{ .id = 1 });

    // The same node keeps its sharedId.
    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{
            .expression = "document.querySelector('#main')",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "node", .sharedId = "1" },
    }, .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "document.getElementById('main')",
            .target = .{ .context = context_id },
            .serializationOptions = .{ .maxDomDepth = 1 },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{
            .type = "node",
            .value = .{
                .children = .{.{
                    .type = "node",
                    .value = .{ .nodeType = 1, .localName = "p", .childNodeCount = 1 },
                }},
            },
        },
    }, .{ .id = 3 });
}

test "bidi.script: evaluate platform objects" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    // NodeList and HTMLCollection are array-likes of nodes.
    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "document.querySelectorAll('#main, p')",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{
            .type = "nodelist",
            .value = .{
                .{ .type = "node", .value = .{ .localName = "div" } },
                .{ .type = "node", .value = .{ .localName = "p" } },
            },
        },
    }, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{
            .expression = "document.getElementsByTagName('p')",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{
            .type = "htmlcollection",
            .value = .{.{ .type = "node", .value = .{ .localName = "p" } }},
        },
    }, .{ .id = 2 });

    // maxObjectDepth applies to them like any other container.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "document.getElementsByTagName('p')",
            .target = .{ .context = context_id },
            .serializationOptions = .{ .maxObjectDepth = 0 },
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "htmlcollection" } }, .{ .id = 3 });
    const bare = try ctx.sentMessage(2);
    try testing.expect(bare.object.get("result").?.object.get("value") == null);

    // Any other platform object is opaque: its type, but not its properties.
    try ctx.processMessage(.{
        .id = 4,
        .method = "script.evaluate",
        .params = .{
            .expression = "navigator",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "object" } }, .{ .id = 4 });
    const opaque_object = try ctx.sentMessage(3);
    try testing.expect(opaque_object.object.get("result").?.object.get("value") == null);
}

test "bidi.script: sharedIds don't survive a navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{ .expression = "document.body", .target = .{ .context = context_id } },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "node", .sharedId = "1" } }, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "browsingContext.navigate",
        .params = .{
            .context = context_id,
            .url = testing.test_server ++ "bidi/values.html",
            .wait = "complete",
        },
    });
    try ctx.wait();

    // The registry was cleared, so the id is gone rather than pointing at a
    // node from the previous document.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(node) => node.tagName",
            .target = .{ .context = context_id },
            .arguments = .{.{ .sharedId = "1" }},
        },
    });
    try ctx.expectSentError("no such node", null, .{ .id = 3 });
}

test "bidi.script: evaluate reports a throw as an exception result" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    // A JS throw isn't a command failure: the reply is a success carrying an
    // exception result.
    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "throw new Error('nope')",
            .target = .{ .context = context_id },
        },
    });
    // The text carries the error's name too — drivers split it back off.
    try ctx.expectSentResult(.{
        .type = "exception",
        .exceptionDetails = .{
            .text = "Error: nope",
            .exception = .{ .type = "error" },
        },
    }, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{
            .expression = "this is not javascript",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{ .type = "exception" }, .{ .id = 2 });
}

test "bidi.script: evaluate awaitPromise" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    // Settling only needs the microtask queue, which we can drain inline.
    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "Promise.resolve(42)",
            .target = .{ .context = context_id },
            .awaitPromise = true,
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "number", .value = 42 },
    }, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{
            .expression = "Promise.reject(new Error('boom'))",
            .target = .{ .context = context_id },
            .awaitPromise = true,
        },
    });
    try ctx.expectSentResult(.{
        .type = "exception",
        .exceptionDetails = .{ .text = "Error: boom", .exception = .{ .type = "error" } },
    }, .{ .id = 2 });

    // Without awaitPromise the promise itself is the result, settled or not.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "Promise.resolve(42)",
            .target = .{ .context = context_id },
            .awaitPromise = false,
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "promise" },
    }, .{ .id = 3 });

    // A promise waiting on a timer needs the event loop: the command stays
    // open and is answered from the callback.
    try ctx.processMessage(.{
        .id = 4,
        .method = "script.evaluate",
        .params = .{
            .expression = "new Promise(r => setTimeout(() => r({n: 42}), 5))",
            .target = .{ .context = context_id },
            .awaitPromise = true,
        },
    });
    try ctx.expectNotAnswered(4);
    try ctx.wait();
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "object", .value = .{.{ "n", .{ .type = "number", .value = 42 } }} },
    }, .{ .id = 4 });

    try ctx.processMessage(.{
        .id = 5,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "() => new Promise((_, reject) => setTimeout(() => reject(new Error('late')), 5))",
            .target = .{ .context = context_id },
            .awaitPromise = true,
        },
    });
    try ctx.wait();
    try ctx.expectSentResult(.{
        .type = "exception",
        .exceptionDetails = .{ .text = "Error: late", .exception = .{ .type = "error" } },
    }, .{ .id = 5 });

    // resultOwnership applies to the settled value, not the promise.
    try ctx.processMessage(.{
        .id = 6,
        .method = "script.evaluate",
        .params = .{
            .expression = "new Promise(r => setTimeout(() => r({}), 5))",
            .target = .{ .context = context_id },
            .awaitPromise = true,
            .resultOwnership = "root",
        },
    });
    try ctx.wait();
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "object", .handle = "1" } }, .{ .id = 6 });
}

test "bidi.script: awaitPromise across a navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    // A promise that never settles: the navigation is what answers it, with
    // an error, so the client isn't left hanging on a realm that's gone.
    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "new Promise(() => {})",
            .target = .{ .context = context_id },
            .awaitPromise = true,
        },
    });
    try ctx.expectNotAnswered(1);

    try ctx.processMessage(.{
        .id = 2,
        .method = "browsingContext.navigate",
        .params = .{
            .context = context_id,
            .url = testing.test_server ++ "bidi/values.html",
            .wait = "complete",
        },
    });
    try ctx.wait();
    try ctx.expectSentError("no such realm", null, .{ .id = 1 });
    try ctx.expectSentResult(null, .{ .id = 2 });

    // The new realm works as usual, timers included.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "new Promise(r => setTimeout(() => r('after'), 5))",
            .target = .{ .context = context_id },
            .awaitPromise = true,
        },
    });
    try ctx.wait();
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "string", .value = "after" } }, .{ .id = 3 });
}

test "bidi.script: callFunction arguments" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(a, b, c) => a + b.n + c.length",
            .target = .{ .context = context_id },
            .arguments = .{
                .{ .type = "number", .value = 1 },
                // An object key is a LocalValue of its own, which is the form
                // drivers send even for a plain object.
                .{ .type = "object", .value = .{.{ .{ .type = "string", .value = "n" }, .{ .type = "number", .value = 2 } }} },
                .{ .type = "array", .value = .{ .{ .type = "boolean", .value = true }, .{ .type = "null" } } },
            },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "number", .value = 5 },
    }, .{ .id = 1 });

    // A bigint argument round-trips beyond 64 bits.
    try ctx.processMessage(.{
        .id = 6,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(b) => b + 1n",
            .target = .{ .context = context_id },
            .arguments = .{.{ .type = "bigint", .value = "340282366920938463463374607431768211456" }},
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "bigint", .value = "340282366920938463463374607431768211457" },
    }, .{ .id = 6 });

    // Plain text is also allowed for a key.
    try ctx.processMessage(.{
        .id = 5,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(o) => o.n",
            .target = .{ .context = context_id },
            .arguments = .{.{ .type = "object", .value = .{.{ "n", .{ .type = "number", .value = 9 } }} }},
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "number", .value = 9 },
    }, .{ .id = 5 });

    // The trailing sourceURL comment drivers append has to survive the wrap
    // that turns the declaration into a callable.
    try ctx.processMessage(.{
        .id = 2,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "() => 'ok'\n//# sourceURL=pptr://__puppeteer_evaluation_script__\n",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "string", .value = "ok" },
    }, .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "function() { return this.n; }",
            .target = .{ .context = context_id },
            .this = .{ .type = "object", .value = .{.{ "n", .{ .type = "string", .value = "this" } }} },
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "string", .value = "this" },
    }, .{ .id = 3 });

    // Parses, but isn't callable. A declaration that doesn't parse at all
    // comes back as an exception result instead.
    try ctx.processMessage(.{
        .id = 4,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "42",
            .target = .{ .context = context_id },
        },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 4 });
}

test "bidi.script: handles" {
    testing.expectLog(&.{.bidi});
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    // resultOwnership "root" keeps the value alive so a later command can
    // refer back to it.
    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "({n: 7})",
            .target = .{ .context = context_id },
            .resultOwnership = "root",
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "object", .handle = "1" },
    }, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(o) => o.n",
            .target = .{ .context = context_id },
            .arguments = .{.{ .handle = "1" }},
        },
    });
    try ctx.expectSentResult(.{
        .type = "success",
        .result = .{ .type = "number", .value = 7 },
    }, .{ .id = 2 });

    // A symbol is a primitive with identity: it gets a handle and round-trips.
    try ctx.processMessage(.{
        .id = 10,
        .method = "script.evaluate",
        .params = .{
            .expression = "window.sym = Symbol('s')",
            .target = .{ .context = context_id },
            .resultOwnership = "root",
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "symbol", .handle = "2" } }, .{ .id = 10 });
    try ctx.processMessage(.{
        .id = 11,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(s) => s === window.sym",
            .target = .{ .context = context_id },
            .arguments = .{.{ .handle = "2" }},
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "boolean", .value = true } }, .{ .id = 11 });
    try ctx.processMessage(.{
        .id = 12,
        .method = "script.disown",
        .params = .{ .handles = .{"2"}, .target = .{ .context = context_id } },
    });
    try ctx.expectSentResult(null, .{ .id = 12 });

    // A primitive has nothing to hold on to, so it gets no handle.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "'plain'",
            .target = .{ .context = context_id },
            .resultOwnership = "root",
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "string" } }, .{ .id = 3 });

    try ctx.processMessage(.{
        .id = 4,
        .method = "script.disown",
        .params = .{ .handles = .{"1"}, .target = .{ .context = context_id } },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });

    try ctx.processMessage(.{
        .id = 5,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(o) => o.n",
            .target = .{ .context = context_id },
            .arguments = .{.{ .handle = "1" }},
        },
    });
    try ctx.expectSentError("no such handle", null, .{ .id = 5 });

    // Disowning an unknown handle is a no-op, not an error: a client that
    // disowns twice is behaving normally.
    try ctx.processMessage(.{
        .id = 6,
        .method = "script.disown",
        .params = .{ .handles = .{"1"}, .target = .{ .context = context_id } },
    });
    try ctx.expectSentResult(null, .{ .id = 6 });

    // A value whose serialization throws gets its handle released again,
    // since the client never learns the id. Ids aren't reused, so the next
    // owned result proves 3 was minted then released: it takes 4, and 3 is
    // unknown.
    try ctx.processMessage(.{
        .id = 7,
        .method = "script.evaluate",
        .params = .{
            .expression = "({ get boom() { throw new Error('nope') } })",
            .target = .{ .context = context_id },
            .resultOwnership = "root",
        },
    });
    try ctx.expectSentError("unknown error", "cannot serialize result", .{ .id = 7 });

    try ctx.processMessage(.{
        .id = 8,
        .method = "script.evaluate",
        .params = .{
            .expression = "({n: 8})",
            .target = .{ .context = context_id },
            .resultOwnership = "root",
        },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "object", .handle = "4" } }, .{ .id = 8 });

    try ctx.processMessage(.{
        .id = 9,
        .method = "script.callFunction",
        .params = .{
            .functionDeclaration = "(o) => o.n",
            .target = .{ .context = context_id },
            .arguments = .{.{ .handle = "3" }},
        },
    });
    try ctx.expectSentError("no such handle", null, .{ .id = 9 });
}

test "bidi.script: target validation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{
            .expression = "1",
            .target = .{ .context = "00000000-0000-0000-0000-000000000000" },
        },
    });
    try ctx.expectSentError("no such frame", "unknown context", .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{ .expression = "1", .target = .{} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 2 });

    // An isolated world would silently run against the wrong globals, so it's
    // refused rather than ignored.
    try ctx.processMessage(.{
        .id = 3,
        .method = "script.evaluate",
        .params = .{
            .expression = "1",
            .target = .{ .context = context_id, .sandbox = "mine" },
        },
    });
    try ctx.expectSentError("unsupported operation", "sandboxes are not supported", .{ .id = 3 });

    // The realm reported alongside a result is also accepted as a target.
    const realm = try testing.arena.dupe(u8, &ctx.bidi().browsing_context.?.realm_id);
    try ctx.processMessage(.{
        .id = 4,
        .method = "script.evaluate",
        .params = .{ .expression = "1", .target = .{ .realm = realm } },
    });
    try ctx.expectSentResult(.{ .type = "success", .realm = realm }, .{ .id = 4 });
}

test "bidi.script: commands need a session" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{
        .id = 1,
        .method = "script.evaluate",
        .params = .{ .expression = "1", .target = .{ .context = "x" } },
    });
    try ctx.expectSentError("invalid session id", "no active session", .{ .id = 1 });

    // The session gate runs before the module resolves its action, so an
    // unknown script command is only reported as such once there's a session.
    try ctx.processMessage(.{ .id = 2, .method = "script.nope" });
    try ctx.expectSentError("invalid session id", "no active session", .{ .id = 2 });

    try ctx.startSession();
    try ctx.processMessage(.{ .id = 3, .method = "script.nope" });
    try ctx.expectSentError("unknown command", "script.nope", .{ .id = 3 });
}

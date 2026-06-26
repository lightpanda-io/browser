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

// QuickJS counterpart of `Runtime.zig`. Where the v8 backend drives a bare
// isolate through the raw `js.v8` C bindings, this drives a bare `JSContext`
// (a fresh context on the agent's own `JSRuntime`, separate from the page's)
// through the raw quickjs `q` bindings. `lightpanda.zig` aliases `Runtime` to
// this when `build_config.v8` is false. The two files mirror each other: the
// engine-agnostic argument marshalling, schema handling and tool dispatch are
// kept structurally identical so behaviour matches across engines.
const std = @import("std");
const lp = @import("lightpanda");

const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const CDPNode = @import("../cdp/Node.zig");
const Schema = @import("Schema.zig");

// The qjs backend's raw quickjs namespace. Imported directly (rather than via
// the `lp.js` facade, which only re-exports v8's raw namespace) because this
// file is only ever analyzed in qjs builds.
const qjs = @import("../browser/js/qjs/js.zig");
const q = qjs.q;

const Runtime = @This();

allocator: std.mem.Allocator,
app: *lp.App,
session: *lp.Session,
registry: *CDPNode.Registry,
env: lp.js.Env,
ctx: ?*q.JSContext,
call_arena: std.heap.ArenaAllocator,
/// Notified before each `console.*` line is written. The REPL uses it to
/// clear the live spinner so script output starts on a clean line instead
/// of colliding with the indicator; the line still goes to stdout/stderr.
console_observer: ?ConsoleObserver = null,

/// The recorded browser tools, in a stable order. The agent installs exactly
/// these as page primitives (the same set the recorder writes); a primitive
/// callback identifies its tool by its `magic` index into this array.
const recorded_tools: []const BrowserTool = blk: {
    var list: []const BrowserTool = &.{};
    for (std.enums.values(BrowserTool)) |t| {
        if (t.isRecorded()) list = list ++ &[_]BrowserTool{t};
    }
    break :blk list;
};

const ConsoleMethod = enum {
    debug,
    @"error",
    info,
    log,
    warn,

    fn writesStderr(self: ConsoleMethod) bool {
        return switch (self) {
            .@"error", .warn => true,
            .debug, .info, .log => false,
        };
    }
};

pub const ConsoleObserver = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) void,
};

pub const InitError = error{
    OutOfMemory,
    RuntimeInitFailed,
    TooManyContexts,
};

pub const RunError = error{
    OutOfMemory,
};

pub fn init(
    allocator: std.mem.Allocator,
    app: *lp.App,
    session: *lp.Session,
    registry: *CDPNode.Registry,
) InitError!*Runtime {
    const self = try allocator.create(Runtime);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .app = app,
        .session = session,
        .registry = registry,
        .env = undefined,
        .ctx = null,
        .call_arena = .init(allocator),
    };
    errdefer self.call_arena.deinit();

    // Separate JSRuntime from the page. The agent context lives here, bare (no
    // WebAPIs), so agent globals never touch the page's window and vice versa.
    self.env = lp.js.Env.init(app, .{}) catch return error.RuntimeInitFailed;
    errdefer self.env.deinit();

    try self.createContext();

    return self;
}

pub fn deinit(self: *Runtime) void {
    self.resetContext();
    self.env.deinit();
    self.call_arena.deinit();
    const allocator = self.allocator;
    allocator.destroy(self);
}

pub fn terminate(self: *Runtime) void {
    self.env.terminate();
}

pub fn cancelTerminate(self: *Runtime) void {
    self.env.cancelTerminate();
}

fn createContext(self: *Runtime) InitError!void {
    // `Env.init` installs a runtime-wide promise-rejection tracker that reads a
    // browser `Context` from the JSContext opaque; our bare context stores a
    // `*Runtime` there instead, and the script body runs inside an async wrapper
    // so unhandled rejections happen routinely. This Env's `JSRuntime` is ours
    // alone (separate from the page's), so clear the tracker to a no-op — the
    // moral equivalent of the v8 backend pinning the reject-callback slot to null.
    q.JS_SetHostPromiseRejectionTracker(self.env.rt, null, null);

    // A bare context: `JS_NewContext` installs the standard intrinsics (Object,
    // JSON, Promise, Error, …) but none of our WebAPI classes, which are only
    // wired up per-context by `Env.createContext` (which we deliberately skip).
    const ctx = q.JS_NewContext(self.env.rt) orelse return error.RuntimeInitFailed;
    errdefer q.JS_FreeContext(ctx);

    // Every callback recovers `*Runtime` from the context opaque, so a bare
    // function (no per-callback External) carries all the state it needs.
    q.JS_SetContextOpaque(ctx, self);

    const global = q.JS_GetGlobalObject(ctx);
    defer q.JS_FreeValue(ctx, global);

    // `Page` is the only global verb; `new Page()` attaches a method for each
    // recorded tool to the new instance (see `construct`).
    const page_ctor = q.JS_NewCFunction2(ctx, @ptrCast(&pageConstructor), "Page", 0, q.JS_CFUNC_constructor, 0);
    _ = q.JS_SetPropertyStr(ctx, global, "Page", page_ctor);

    try installConsole(ctx, global);

    self.ctx = ctx;
}

fn resetContext(self: *Runtime) void {
    const ctx = self.ctx orelse return;
    q.JS_FreeContext(ctx);
    self.ctx = null;
}

fn installConsole(ctx: *q.JSContext, global: q.JSValue) InitError!void {
    const console = q.JS_NewObject(ctx);
    for (std.enums.values(ConsoleMethod), 0..) |method, i| {
        const func = q.JS_NewCFunction2(ctx, @ptrCast(&consoleCallback), @tagName(method), 1, q.JS_CFUNC_generic_magic, @intCast(i));
        _ = q.JS_SetPropertyStr(ctx, console, @tagName(method), func);
    }
    _ = q.JS_SetPropertyStr(ctx, global, "console", console);
}

/// Run script source in the agent context. Returns null on success; on a JS
/// compile/runtime exception returns a formatted error allocated in this
/// runtime's call arena and valid until deinit or the next run.
pub fn runSource(self: *Runtime, source: []const u8, name: []const u8) RunError!?[]const u8 {
    _ = self.call_arena.reset(.retain_capacity);
    const arena = self.call_arena.allocator();

    const ctx = self.ctx orelse return try self.dupeError("agent script context is not available");

    // Wrap in an async IIFE so the source can use top-level `await` (e.g.
    // `await page.goto(...)`). The wrapper evaluates to a Promise; a top-level
    // `return <expr>` becomes that Promise's value, which we echo. (A bare
    // trailing expression no longer auto-prints — `await` and a script
    // completion value are mutually exclusive in JS.)
    const wrapped = std.fmt.allocPrintSentinel(arena, "(async () => {{\n{s}\n}})()", .{source}, 0) catch
        return try self.dupeError("out of memory");
    const filename = arena.dupeZ(u8, name) catch return try self.dupeError("out of memory");

    const completion = q.JS_Eval(ctx, wrapped.ptr, wrapped.len, filename.ptr, q.JS_EVAL_TYPE_GLOBAL);
    defer q.JS_FreeValue(ctx, completion);

    // A compile error (or a terminate interrupt) surfaces here; a runtime throw
    // inside the async body instead rejects the returned promise (below).
    if (q.JS_IsException(completion)) {
        return try self.formatCaught(ctx, "script failed");
    }

    // `goto` runs synchronously and resolves its Promise before returning, so
    // draining the job queue settles the whole `await` chain — no event loop.
    // (Truly-async navigation is a later change.)
    self.env.runMicrotasks();

    const state = q.JS_PromiseState(ctx, completion);
    // A still-pending root means the script awaited something we can't settle
    // (no async navigation is in flight) — stay silent.
    if (state != q.JS_PROMISE_FULFILLED and state != q.JS_PROMISE_REJECTED) return null;

    const result = q.JS_PromiseResult(ctx, completion);
    defer q.JS_FreeValue(ctx, result);
    if (state == q.JS_PROMISE_REJECTED) return try self.formatRejection(ctx, result);
    self.printCompletion(ctx, result);
    return null;
}

/// Format a script's rejection reason into a run-arena message. Prefers a thrown
/// Error's `.message` so the caller's own "Error:" label isn't doubled
/// (coercing an Error to string yields "Error: <message>").
fn formatRejection(self: *Runtime, ctx: *q.JSContext, reason: q.JSValueConst) RunError![]const u8 {
    const arena = self.call_arena.allocator();
    if (q.JS_IsObject(reason)) {
        const message = q.JS_GetPropertyStr(ctx, reason, "message");
        defer q.JS_FreeValue(ctx, message);
        if (q.JS_IsString(message)) {
            const text = self.stringify(arena, ctx, message) catch return try self.dupeError("script failed");
            return text;
        }
    }
    const text = self.stringify(arena, ctx, reason) catch return try self.dupeError("script failed");
    return text;
}

/// Format the currently-pending exception (from a compile error or a synchronous
/// throw) into a run-arena message.
fn formatCaught(self: *Runtime, ctx: *q.JSContext, fallback: []const u8) RunError![]const u8 {
    const arena = self.call_arena.allocator();
    const exception = q.JS_GetException(ctx);
    defer q.JS_FreeValue(ctx, exception);
    const text = self.stringify(arena, ctx, exception) catch return try self.dupeError(fallback);
    return text;
}

/// Echo a script's output — the value it `return`s from the async wrapper, so a
/// script ending in `return page.extract(...)` prints without `console.log`.
/// `undefined` — no `return`, or a bare trailing expression — stays silent.
fn printCompletion(self: *Runtime, ctx: *q.JSContext, value: q.JSValueConst) void {
    if (q.JS_IsUndefined(value)) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const text = self.displayString(arena_state.allocator(), ctx, value) catch return;
    self.writeConsoleLine(.log, text);
}

fn runtimeFromCtx(ctx: ?*q.JSContext) *Runtime {
    return @ptrCast(@alignCast(q.JS_GetContextOpaque(ctx).?));
}

// == Callbacks ==

fn pageConstructor(ctx: ?*q.JSContext, this_val: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst) callconv(.c) q.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return runtimeFromCtx(ctx).construct(ctx.?);
}

fn primitiveCallback(ctx: ?*q.JSContext, this_val: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, magic: c_int) callconv(.c) q.JSValue {
    const self = runtimeFromCtx(ctx);
    return self.invoke(ctx.?, recorded_tools[@intCast(magic)], this_val, argc, argv);
}

fn closeCallback(ctx: ?*q.JSContext, this_val: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, magic: c_int) callconv(.c) q.JSValue {
    _ = argc;
    _ = argv;
    _ = magic;
    runtimeFromCtx(ctx).invokeClose(ctx.?, this_val);
    return qjs.UNDEFINED;
}

fn consoleCallback(ctx: ?*q.JSContext, this_val: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, magic: c_int) callconv(.c) q.JSValue {
    _ = this_val;
    const self = runtimeFromCtx(ctx);
    self.invokeConsole(ctx.?, std.enums.values(ConsoleMethod)[@intCast(magic)], argc, argv);
    return qjs.UNDEFINED;
}

/// `new Page()`: attach a method for every recorded tool (including `goto`) plus
/// `close`. `__lpFrameId` is left unset until the first `goto` navigates the page.
fn construct(self: *Runtime, ctx: *q.JSContext) q.JSValue {
    _ = self;
    const obj = q.JS_NewObject(ctx);
    for (recorded_tools, 0..) |tool, i| {
        const func = q.JS_NewCFunction2(ctx, @ptrCast(&primitiveCallback), @tagName(tool), 1, q.JS_CFUNC_generic_magic, @intCast(i));
        _ = q.JS_SetPropertyStr(ctx, obj, @tagName(tool), func);
    }
    const close = q.JS_NewCFunction2(ctx, @ptrCast(&closeCallback), "close", 0, q.JS_CFUNC_generic_magic, 0);
    _ = q.JS_SetPropertyStr(ctx, obj, "close", close);
    return obj;
}

/// Property carrying a page handle's claim on a live frame. Numeric while the
/// page is navigated; absent/undefined once never-navigated or closed.
const frame_id_key = "__lpFrameId";

/// `page.close()`: stale the wrapper so later method calls error. A single
/// synchronous page has no popups to free; the active page is reclaimed on the
/// next `goto` or at script end.
fn invokeClose(self: *Runtime, ctx: *q.JSContext, this: q.JSValueConst) void {
    _ = self;
    _ = q.JS_SetPropertyStr(ctx, this, frame_id_key, qjs.UNDEFINED);
}

fn invoke(self: *Runtime, ctx: *q.JSContext, tool: BrowserTool, this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst) q.JSValue {
    // Owned, not shared: marshalling runs JS (`toJSON`) that can re-enter a
    // primitive; a shared arena would let the nested call reset ours mid-flight.
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = self.buildArgs(arena, ctx, tool, argc, argv) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError(ctx, "out of memory"),
        error.JsException => return qjs.EXCEPTION, // a JS exception is already pending
        error.InvalidArguments => return self.throwTypeError(ctx, "invalid arguments"),
    };

    // `goto` is the one async-shaped primitive: it returns a Promise (resolved
    // synchronously once the blocking navigation settles).
    if (tool == .goto) return self.invokeGoto(arena, ctx, this, args);

    // Other primitives are page methods. The receiver must be navigated, and —
    // since a single synchronous page has only one live frame — still be the
    // current one; a later `goto` (on any handle) replaces the page and stales
    // every other handle.
    const frame_id = self.receiverFrameId(ctx, this) orelse
        return self.throwError(ctx, "page is not navigated or has been closed; call page.goto(url) first");
    const live = self.session.currentFrame();
    if (live == null or live.?._frame_id != frame_id) {
        return self.throwError(ctx, "page handle is no longer valid; the page was closed or replaced");
    }

    const result = self.callTool(arena, tool, args) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError(ctx, "out of memory"),
    };

    switch (result) {
        .ok => |text| switch (tool) {
            .extract => {
                const normalized = self.normalizeExtractReturnJson(arena, text) catch |err| switch (err) {
                    error.OutOfMemory => return self.throwError(ctx, "out of memory"),
                };
                return self.makeReturnJson(arena, ctx, normalized) catch
                    return self.throwError(ctx, "out of memory");
            },
            else => return q.JS_NewStringLen(ctx, text.ptr, text.len),
        },
        .fail => |message| return self.throwError(ctx, message),
    }
}

/// Navigate the receiver Page synchronously and hand back a resolved Promise of
/// the page object, so `await page.goto(url)` yields the page. The blocking
/// `goto` tool runs the navigation to completion before this returns; on success
/// the receiver's `__lpFrameId` is (re)bound to the freshly-loaded frame.
fn invokeGoto(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    this: q.JSValueConst,
    args: ?std.json.Value,
) q.JSValue {
    var funcs: [2]q.JSValue = undefined;
    const promise = q.JS_NewPromiseCapability(ctx, &funcs);
    if (q.JS_IsException(promise)) return self.throwError(ctx, "internal: resolver alloc failed");
    defer q.JS_FreeValue(ctx, funcs[0]);
    defer q.JS_FreeValue(ctx, funcs[1]);

    const result = self.callTool(arena, .goto, args) catch |err| switch (err) {
        error.OutOfMemory => {
            self.rejectResolver(ctx, funcs[1], "out of memory");
            return promise;
        },
    };

    switch (result) {
        .ok => {
            const frame = self.session.currentFrame() orelse {
                self.rejectResolver(ctx, funcs[1], "navigation failed");
                return promise;
            };
            self.bindFrameId(ctx, this, frame._frame_id);
            self.resolveResolver(ctx, funcs[0], this);
        },
        .fail => |message| self.rejectResolver(ctx, funcs[1], message),
    }
    return promise;
}

fn resolveResolver(self: *Runtime, ctx: *q.JSContext, resolve: q.JSValueConst, value: q.JSValueConst) void {
    _ = self;
    var args = [_]q.JSValueConst{value};
    const ret = q.JS_Call(ctx, resolve, qjs.UNDEFINED, args.len, &args);
    q.JS_FreeValue(ctx, ret);
}

fn rejectResolver(self: *Runtime, ctx: *q.JSContext, reject: q.JSValueConst, message: []const u8) void {
    _ = self;
    const err = q.JS_NewError(ctx);
    _ = q.JS_SetPropertyStr(ctx, err, "message", q.JS_NewStringLen(ctx, message.ptr, message.len));
    var args = [_]q.JSValueConst{err};
    const ret = q.JS_Call(ctx, reject, qjs.UNDEFINED, args.len, &args);
    q.JS_FreeValue(ctx, ret);
    q.JS_FreeValue(ctx, err);
}

/// Bind `__lpFrameId` on a page object to `frame_id` — the handle's claim on the
/// live frame, checked by `invoke` on every later method call.
fn bindFrameId(self: *Runtime, ctx: *q.JSContext, this: q.JSValueConst, frame_id: u32) void {
    _ = self;
    _ = q.JS_SetPropertyStr(ctx, this, frame_id_key, q.JS_NewUint32(ctx, frame_id));
}

/// Frame id a method's receiver was bound to (`this.__lpFrameId`), or null when
/// the page was never navigated or has been closed.
fn receiverFrameId(self: *Runtime, ctx: *q.JSContext, this: q.JSValueConst) ?u32 {
    _ = self;
    const prop = q.JS_GetPropertyStr(ctx, this, frame_id_key);
    defer q.JS_FreeValue(ctx, prop);
    if (!q.JS_IsNumber(prop)) return null;
    var out: u32 = undefined;
    if (q.JS_ToUint32(ctx, &out, prop) != 0) return null;
    return out;
}

fn invokeConsole(self: *Runtime, ctx: *q.JSContext, method: ConsoleMethod, argc: c_int, argv: [*c]q.JSValueConst) void {
    // Owned arena (see `invoke`): an argument's `toString` can re-enter a
    // primitive mid-loop and must not reset the buffer we're accumulating.
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    for (0..@intCast(argc)) |i| {
        if (i > 0) aw.writer.writeByte(' ') catch return;
        const text = self.stringify(arena, ctx, argv[i]) catch "<unprintable>";
        aw.writer.writeAll(text) catch return;
    }

    self.writeConsoleLine(method, aw.written());
}

fn writeConsoleLine(self: *Runtime, method: ConsoleMethod, line: []const u8) void {
    if (self.console_observer) |obs| obs.notify(obs.context);
    var buf: [4096]u8 = undefined;
    var file = if (method.writesStderr()) std.fs.File.stderr() else std.fs.File.stdout();
    var writer = file.writer(&buf);
    writer.interface.print("{s}\n", .{line}) catch return;
    writer.interface.flush() catch return;
}

const PrimitiveResult = union(enum) {
    ok: []const u8,
    fail: []const u8,
};

fn callTool(
    self: *Runtime,
    arena: std.mem.Allocator,
    tool: BrowserTool,
    args: ?std.json.Value,
) error{OutOfMemory}!PrimitiveResult {
    const result = browser_tools.call(arena, self.session, self.registry, @tagName(tool), args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FrameNotLoaded => return .{ .fail = "no page loaded - run page.goto(url) first" },
        else => return .{ .fail = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ @tagName(tool), @errorName(err) }) catch return error.OutOfMemory },
    };

    if (result.is_error) return .{ .fail = result.text };
    return .{ .ok = result.text };
}

// == Argument marshalling (engine-agnostic; mirrors Runtime.zig) ==

const BuildArgsError = error{
    OutOfMemory,
    JsException,
    InvalidArguments,
};

fn buildArgs(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    tool: BrowserTool,
    argc: c_int,
    argv: [*c]q.JSValueConst,
) BuildArgsError!?std.json.Value {
    const count: usize = @intCast(argc);
    return switch (tool) {
        .extract => try self.extractArgs(arena, ctx, argv, count),
        else => try self.marshalArgs(arena, ctx, argv, count, Schema.positionalFor(tool)),
    };
}

/// Marshals `tool(positionals…, options?)` into the args object `browser_tools.call`
/// expects: leading primitives bind to `positional` by index (a `null` omits its
/// field), a trailing object merges as options (conflict on a repeated field), and a
/// lone object passes through. Positionals stay opaque; the tool's parser types them.
fn marshalArgs(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    argv: [*c]q.JSValueConst,
    argc: usize,
    positional: []const []const u8,
) BuildArgsError!std.json.Value {
    const values = try arena.alloc(std.json.Value, argc);
    for (values, 0..) |*v, i| v.* = try self.argJson(arena, ctx, argv, i);

    if (argc == 1 and values[0] == .object) return values[0];

    // A trailing object is the options bag; everything before it is positional.
    var positional_count = argc;
    var options: ?std.json.ObjectMap = null;
    if (argc > 0 and values[argc - 1] == .object) {
        options = values[argc - 1].object;
        positional_count = argc - 1;
    }
    if (positional_count > positional.len) return error.InvalidArguments;

    var obj: std.json.ObjectMap = .init(arena);
    for (values[0..positional_count], positional[0..positional_count]) |v, field| {
        switch (v) {
            .null => {}, // omit the field — e.g. page/focused-level selector
            .object, .array => return error.InvalidArguments,
            else => try obj.put(field, v),
        }
    }
    if (options) |opts| {
        var it = opts.iterator();
        while (it.next()) |entry| {
            if (obj.contains(entry.key_ptr.*)) return error.InvalidArguments;
            try obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return .{ .object = obj };
}

fn extractArgs(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    argv: [*c]q.JSValueConst,
    argc: usize,
) BuildArgsError!std.json.Value {
    if (argc != 1) return error.InvalidArguments;
    const value = try self.argJson(arena, ctx, argv, 0);
    const schema = switch (value) {
        .string, .array => try extractSchemaString(arena, value),
        .object => |obj| if (obj.get("schema")) |inner| blk: {
            if (obj.count() != 1) return error.InvalidArguments;
            break :blk try extractSchemaString(arena, inner);
        } else try extractSchemaString(arena, value),
        else => return error.InvalidArguments,
    };
    return try objectWith(arena, "schema", .{ .string = schema });
}

fn extractSchemaString(arena: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}![]const u8 {
    return switch (value) {
        .string => |str| normalizeExtractSchemaString(arena, str),
        .array => |arr| normalizeExtractSchemaString(
            arena,
            try std.json.Stringify.valueAlloc(arena, std.json.Value{ .array = arr }, .{}),
        ),
        else => try std.json.Stringify.valueAlloc(arena, value, .{}),
    };
}

fn normalizeExtractSchemaString(arena: std.mem.Allocator, schema: []const u8) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, schema, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '[') return schema;
    return try std.fmt.allocPrint(arena, "{{\"__root\":{s}}}", .{schema});
}

fn argJson(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    argv: [*c]q.JSValueConst,
    index: usize,
) BuildArgsError!std.json.Value {
    return self.valueToJson(arena, ctx, argv[index]);
}

fn valueToJson(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    value: q.JSValueConst,
) BuildArgsError!std.json.Value {
    _ = self;
    const json_value = q.JS_JSONStringify(ctx, value, qjs.UNDEFINED, qjs.UNDEFINED);
    defer q.JS_FreeValue(ctx, json_value);
    // A pending exception (circular structure, BigInt, …) — propagate it.
    if (q.JS_IsException(json_value)) return error.JsException;
    // `JSON.stringify` of `undefined`/a function yields the JS value `undefined`,
    // not a string — treat as a missing argument.
    if (!q.JS_IsString(json_value)) return error.InvalidArguments;

    var len: usize = undefined;
    const cstr = q.JS_ToCStringLen2(ctx, &len, json_value, false) orelse return error.JsException;
    defer q.JS_FreeCString(ctx, cstr);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, cstr[0..len], .{}) catch error.InvalidArguments;
}

fn objectWith(arena: std.mem.Allocator, key: []const u8, value: std.json.Value) error{OutOfMemory}!std.json.Value {
    var obj: std.json.ObjectMap = .init(arena);
    try obj.put(key, value);
    return .{ .object = obj };
}

/// Unwraps only the `__root` sentinel that `normalizeExtractSchemaString` injects
/// for array schemas; a real single-field object schema keeps its shape.
fn normalizeExtractReturnJson(_: *Runtime, arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    if (value.len == 0) return value;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return value,
    };
    if (parsed != .object or parsed.object.count() != 1) return value;

    var it = parsed.object.iterator();
    const entry = it.next() orelse return value;
    if (!std.mem.eql(u8, entry.key_ptr.*, "__root")) return value;
    return try std.json.Stringify.valueAlloc(arena, entry.value_ptr.*, .{});
}

// == JS value helpers ==

fn makeReturnJson(self: *Runtime, arena: std.mem.Allocator, ctx: *q.JSContext, value: []const u8) error{OutOfMemory}!q.JSValue {
    if (value.len == 0) return qjs.UNDEFINED;
    // quickjs' JSON parser reads a NUL terminator as end-of-input, so the
    // length alone is not enough — hand it a sentinel-terminated copy.
    const json = try arena.dupeZ(u8, value);
    const parsed = q.JS_ParseJSON(ctx, json.ptr, json.len, "<extract>");
    if (q.JS_IsException(parsed)) {
        q.JS_FreeValue(ctx, parsed);
        return self.throwError(ctx, "extract returned invalid JSON");
    }
    return parsed;
}

fn throwError(self: *Runtime, ctx: *q.JSContext, message: []const u8) q.JSValue {
    _ = self;
    const err = q.JS_NewError(ctx);
    _ = q.JS_SetPropertyStr(ctx, err, "message", q.JS_NewStringLen(ctx, message.ptr, message.len));
    return q.JS_Throw(ctx, err);
}

fn throwTypeError(self: *Runtime, ctx: *q.JSContext, comptime message: [:0]const u8) q.JSValue {
    _ = self;
    return q.JS_ThrowTypeError(ctx, "%s", message.ptr);
}

/// Coerce any JS value to an owned UTF-8 string (via `ToString`).
fn stringify(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    value: q.JSValueConst,
) error{ OutOfMemory, JsException }![]const u8 {
    _ = self;
    var len: usize = undefined;
    const cstr = q.JS_ToCStringLen2(ctx, &len, value, false) orelse return error.JsException;
    defer q.JS_FreeCString(ctx, cstr);
    return arena.dupe(u8, cstr[0..len]) catch error.OutOfMemory;
}

/// Display form for the script's completion value: objects and arrays as JSON
/// (plain coercion gives a useless `[object Object]`), every other value via that
/// coercion. Falls back to coercion when `JSON.stringify` yields no string — a
/// thrown circular reference, or a value (e.g. a function) that stringifies to
/// `undefined`; a stringify throw is cleared so it doesn't leak to the caller.
fn displayString(
    self: *Runtime,
    arena: std.mem.Allocator,
    ctx: *q.JSContext,
    value: q.JSValueConst,
) error{ OutOfMemory, JsException }![]const u8 {
    if (q.JS_IsObject(value)) {
        const json = q.JS_JSONStringify(ctx, value, qjs.UNDEFINED, qjs.UNDEFINED);
        if (q.JS_IsException(json)) {
            // Clear the pending stringify exception; fall back to coercion.
            const pending = q.JS_GetException(ctx);
            q.JS_FreeValue(ctx, pending);
        } else {
            defer q.JS_FreeValue(ctx, json);
            if (q.JS_IsString(json)) return self.stringify(arena, ctx, json);
        }
    }
    return self.stringify(arena, ctx, value);
}

fn dupeError(self: *Runtime, message: []const u8) RunError![]const u8 {
    return self.call_arena.allocator().dupe(u8, message) catch error.OutOfMemory;
}

const testing = @import("../testing.zig");

fn runTestScript(runtime: *Runtime, source: []const u8) !void {
    if (try runtime.runSource(source, "agent-runtime-test.js")) |message| {
        std.debug.print("agent script failed:\n{s}\n", .{message});
        return error.AgentScriptFailed;
    }
}

fn terminateRuntimeSoon(runtime: *Runtime) void {
    std.Thread.sleep(10 * std.time.ns_per_ms);
    runtime.terminate();
}

test "agent script runtime: goto and evaluate dispatch through browser tools" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const page = new Page();
        \\const same = await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (same !== page) throw new Error("page.goto should resolve the same page object");
        \\const text = page.evaluate("document.getElementById('btn').textContent");
        \\if (text !== "Click Me") throw new Error("evaluate ran in the wrong context: " + text);
    );

    const frame = testing.test_session.currentFrame().?;
    try testing.expect(std.mem.indexOf(u8, frame.url, "/src/browser/tests/mcp_actions.html") != null);
}

test "agent script runtime: Page must be called with new" {
    defer testing.reset();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    const message = (try runtime.runSource("Page();", "agent-runtime-page-no-new.js")).?;
    try testing.expect(std.mem.indexOf(u8, message, "must be called with new") != null);
}

test "agent script runtime: a method on an un-navigated page errors" {
    defer testing.reset();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    const message = (try runtime.runSource(
        \\const page = new Page();
        \\page.extract({ btn: "#btn" });
    , "agent-runtime-not-navigated.js")).?;
    try testing.expect(std.mem.indexOf(u8, message, "not navigated") != null);
}

test "agent script runtime: page.close stales the handle" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    // After close() the wrapper is stale; a later method call must error rather
    // than silently hit whatever page happens to be current.
    const message = (try runtime.runSource(
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\page.close();
        \\page.extract({ btn: "#btn" });
    , "agent-runtime-close.js")).?;
    try testing.expect(std.mem.indexOf(u8, message, "closed") != null);
}

test "agent script runtime: a stale page handle is a hard error" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    // The first page goes stale once a second goto replaces the page; reading
    // through it must throw, not silently hit the current page.
    const message = (try runtime.runSource(
        \\const a = new Page();
        \\await a.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\await new Page().goto("http://localhost:9582/src/browser/tests/runner/runner1.html");
        \\a.extract({ btn: "#btn" });
    , "agent-runtime-stale-handle.js")).?;

    try testing.expect(std.mem.indexOf(u8, message, "no longer valid") != null);
}

test "agent script runtime: extract returns a JavaScript object" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\const data = page.extract({
        \\  button: "#btn",
        \\  options: [{
        \\    selector: "#sel option",
        \\    limit: 2,
        \\    fields: {
        \\      text: "",
        \\      value: { attr: "value" }
        \\    }
        \\  }]
        \\});
        \\if (typeof data !== "object" || data === null || Array.isArray(data)) throw new Error("extract did not return an object");
        \\if (data.button !== "Click Me") throw new Error("unexpected button text: " + data.button);
        \\if (data.options.length !== 2) throw new Error("unexpected option count: " + data.options.length);
        \\if (data.options[1].value !== "opt2") throw new Error("unexpected option value: " + data.options[1].value);
        \\const options = page.extract({
        \\  options: [{
        \\    selector: "#sel option",
        \\    limit: 2,
        \\    fields: {
        \\      text: "",
        \\      value: { attr: "value" }
        \\    }
        \\  }]
        \\});
        \\if (typeof options !== "object" || options === null || Array.isArray(options)) throw new Error("single object field should stay an object");
        \\if (options.options[0].text !== "Option 1") throw new Error("unexpected option text: " + options.options[0].text);
        \\const direct = page.extract([{ selector: "#sel option", limit: 1 }]);
        \\if (!Array.isArray(direct)) throw new Error("array schema should return an array");
        \\if (direct[0] !== "Option 1") throw new Error("unexpected direct array extract: " + direct[0]);
        \\const saveField = page.extract({ save: "#btn" });
        \\if (saveField.save !== "Click Me") throw new Error("top-level save field should be schema data");
        \\let rejectedSaveOption = false;
        \\try {
        \\  page.extract({ schema: { button: "#btn" }, save: "snap" });
        \\} catch (err) {
        \\  rejectedSaveOption = true;
        \\}
        \\if (!rejectedSaveOption) throw new Error("extract save option should be rejected");
    );
}

test "agent script runtime: extract tolerates list selectors that match nothing" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\const empty = page.extract({ comments: [{ selector: ".no-such-element", fields: { text: "" } }] });
        \\if (!Array.isArray(empty.comments) || empty.comments.length !== 0) throw new Error("empty list selector should yield an empty array, not throw");
        \\const bare = page.extract([".no-such-element"]);
        \\if (!Array.isArray(bare) || bare.length !== 0) throw new Error("bare empty array schema should yield an empty array");
        \\const mixed = page.extract({ button: "#btn", comments: [".no-such-element"] });
        \\if (mixed.button !== "Click Me" || mixed.comments.length !== 0) throw new Error("a matched scalar beside an empty list should still resolve");
        \\let threwOnAllNull = false;
        \\try {
        \\  page.extract({ missing: "#does-not-exist" });
        \\} catch (err) {
        \\  threwOnAllNull = true;
        \\}
        \\if (!threwOnAllNull) throw new Error("an all-null scalar schema should still throw");
    );
}

test "agent script runtime: strict-mode scripts can call primitives" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\"use strict";
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\const text = page.evaluate("document.getElementById('btn').textContent");
        \\if (text !== "Click Me") throw new Error("strict-mode evaluate failed: " + text);
    );
}

test "agent script runtime: promise microtasks run to completion" {
    defer testing.reset();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\globalThis.microtaskRan = false;
        \\Promise.resolve().then(() => { globalThis.microtaskRan = true; });
        \\if (globalThis.microtaskRan) throw new Error("microtask ran before the checkpoint");
    );

    try runTestScript(runtime,
        \\if (!globalThis.microtaskRan) throw new Error("microtask did not run after the script");
    );
}

test "agent script runtime: primitives re-entered from argument callbacks stay isolated" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\// toJSON re-enters evaluate mid-marshal; the outer extract must still see "#btn".
        \\const data = page.extract({ button: { toJSON() { return page.evaluate("'#btn'"); } } });
        \\if (data.button !== "Click Me") throw new Error("re-entrant extract corrupted: " + JSON.stringify(data));
        \\// toString re-enters a primitive mid-loop; the console buffer must survive.
        \\let probed = 0;
        \\console.log("value", { toString() { probed += 1; return page.evaluate("'ok'"); } }, "tail");
        \\if (probed !== 1) throw new Error("console toString re-entry not exercised");
    );
}

test "agent script runtime: terminate interrupts local JavaScript" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    const thread = try std.Thread.spawn(.{}, terminateRuntimeSoon, .{runtime});
    defer runtime.cancelTerminate();
    defer thread.join();

    const message = try runtime.runSource("while (true) {}", "agent-runtime-terminate-test.js");
    try testing.expect(message != null);
}

test "agent script runtime: agent variables persist and page globals are isolated" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\globalThis.counter = 1;
        \\if (typeof window !== "undefined") throw new Error("window leaked into agent runtime");
        \\if (typeof document !== "undefined") throw new Error("document leaked into agent runtime");
        \\await new Page().goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\globalThis.counter += 1;
        \\if (globalThis.counter !== 2) throw new Error("agent global state did not persist");
    );

    try runTestScript(runtime,
        \\globalThis.counter += 1;
        \\if (globalThis.counter !== 3) throw new Error("agent global state was reset between scripts");
    );
}

test "agent script runtime: page evaluate cannot see agent primitives or bindings" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const agentOnly = "secret";
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (page.evaluate("typeof Page") !== "undefined") throw new Error("agent primitive leaked to page evaluate");
        \\if (page.evaluate("typeof agentOnly") !== "undefined") throw new Error("agent binding leaked to page evaluate");
        \\if (page.evaluate("typeof document") !== "object") throw new Error("page evaluate did not run in the page context");
    );
}

test "agent script runtime: console is available in agent context" {
    defer testing.reset();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\if (typeof console !== "object") throw new Error("missing console");
        \\if (typeof console.log !== "function") throw new Error("missing console.log");
        \\console.log("agent console ready");
    );
}

test "agent script runtime: tool errors throw and stop execution" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    const message = (try runtime.runSource(
        \\globalThis.marker = "before";
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\page.click({ selector: "#does-not-exist" });
        \\globalThis.marker = "after";
    , "agent-runtime-failure.js")).?;

    try testing.expect(std.mem.indexOf(u8, message, "click") != null or
        std.mem.indexOf(u8, message, "NodeNotFound") != null or
        std.mem.indexOf(u8, message, "#does-not-exist") != null);

    try runTestScript(runtime,
        \\if (globalThis.marker !== "before") throw new Error("script continued after tool failure");
    );
}

test "agent script runtime: builtin argument marshalling (positional + options)" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\// The reported bug: Playwright-style goto(url, options) must merge, not throw.
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html", { timeout: 5000 });
        \\// waitForState: single required param, positional like waitForSelector.
        \\if (!page.waitForState("load").includes("reached")) throw new Error("waitForState positional failed");
        \\// Object form still works; re-navigation rebinds the same page object.
        \\await page.goto({ url: "http://localhost:9582/src/browser/tests/mcp_actions.html", timeout: 5000 });
        \\// Single selector positional.
        \\page.click("#btn");
        \\if (page.evaluate("String(window.clicked)") !== "true") throw new Error("click positional failed");
        \\// Two positionals: selector, value.
        \\page.fill("#inp", "hello");
        \\if (page.evaluate("window.inputVal") !== "hello") throw new Error("fill two-positional failed");
        \\page.selectOption("#sel", "opt2");
        \\if (page.evaluate("window.selChanged") !== "opt2") throw new Error("selectOption two-positional failed");
        \\// Bool positional, and the default-true shorthand when omitted. Assert via the
        \\// tool's own report (the synthetic click toggles the DOM state, so .checked is
        \\// not a reliable observation of the `checked` argument).
        \\if (!page.setChecked("#chk").includes("to checked")) throw new Error("setChecked default-true failed");
        \\if (!page.setChecked("#chk", false).includes("to unchecked")) throw new Error("setChecked bool positional failed");
        \\// Selector-first press, and a null selector for a page/focused key press.
        \\page.press("#keyTarget", "Enter");
        \\if (page.evaluate("window.keyPressed") !== "Enter") throw new Error("selector-first press failed");
        \\page.press(null, "a");
    );

    // A field set by both a positional and the options object is a conflict.
    {
        const message = (try runtime.runSource(
            \\await new Page().goto("http://localhost:9582/src/browser/tests/mcp_actions.html", { url: "http://other" });
        , "agent-runtime-conflict.js")).?;
        try testing.expect(std.mem.indexOf(u8, message, "invalid arguments") != null);
    }

    // More positionals than the tool has fields throws.
    {
        const message = (try runtime.runSource(
            \\const page = new Page();
            \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
            \\page.click("#btn", "#extra");
        , "agent-runtime-arity.js")).?;
        try testing.expect(std.mem.indexOf(u8, message, "invalid arguments") != null);
    }
}

test "agent script runtime: top-level await runs in an async wrapper" {
    defer testing.reset();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    // `await` on a non-goto promise resolves without touching the browser, and
    // a top-level `return` surfaces as the (otherwise un-echoed) result.
    try runTestScript(runtime,
        \\const x = await Promise.resolve(40);
        \\if (x + 2 !== 42) throw new Error("top-level await did not resolve: " + x);
        \\return x + 2;
    );
}

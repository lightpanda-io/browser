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
const TickResult = lp.Session.Runner.TickResult;

const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const CDPNode = @import("../cdp/Node.zig");
const Schema = @import("Schema.zig");

const Runtime = @This();

allocator: std.mem.Allocator,
app: *lp.App,
session: *lp.Session,
registry: *CDPNode.Registry,
env: lp.js.Env,
context: ?*lp.js.Context = null,
call_arena: std.heap.ArenaAllocator,
// Backs the bare context's `call_arena` (reset by `js.Caller` per top-level
// callback) — kept separate from `call_arena`, which holds run-scoped data.
ctx_call_arena: std.heap.ArenaAllocator,
primitive_data: [recorded_tool_count]PrimitiveData,
console_data: [std.enums.values(ConsoleMethod).len]ConsoleData,
/// Notified before each `console.*` line is written. The REPL uses it to
/// clear the live spinner so script output starts on a clean line instead
/// of colliding with the indicator; the line still goes to stdout/stderr.
console_observer: ?ConsoleObserver = null,

/// In-flight `goto` navigations the driver loop settles. Concurrent gotos open
/// popup frames so they coexist; a sequential goto replaces the page.
pending_gotos: std.ArrayList(PendingGoto) = .empty,

/// The runtime installs exactly the recorded browser tools as script
/// primitives — the same set the recorder writes — so every recorded call
/// replays. `buildArgs` adapts each tool's JS calling convention to the JSON
/// `browser_tools.call` expects.
const recorded_tool_count = blk: {
    var n: usize = 0;
    for (std.enums.values(BrowserTool)) |t| {
        if (t.isRecorded()) n += 1;
    }
    break :blk n;
};

const PrimitiveData = struct {
    runtime: *Runtime,
    tool: BrowserTool,
};

const PendingGoto = struct {
    frame_id: u32,
    resolver: lp.js.PromiseResolver.Global,
    deadline_ms: i64,
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

const ConsoleData = struct {
    runtime: *Runtime,
    method: ConsoleMethod,
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
        .call_arena = .init(allocator),
        .ctx_call_arena = .init(allocator),
        .primitive_data = undefined,
        .console_data = undefined,
    };
    errdefer self.call_arena.deinit();
    errdefer self.ctx_call_arena.deinit();

    // Separate isolate from the page. The full `Env` is used only as an isolate
    // + terminate/microtask carrier; the agent context is bare (no WebAPIs).
    self.env = lp.js.Env.init(app, .{}) catch return error.RuntimeInitFailed;
    errdefer self.env.deinit();

    try self.createContext();
    errdefer self.resetContext();

    return self;
}

pub fn deinit(self: *Runtime) void {
    self.clearPendingGotos();
    self.pending_gotos.deinit(self.allocator);
    self.resetContext();
    self.env.deinit();
    self.call_arena.deinit();
    self.ctx_call_arena.deinit();
    const allocator = self.allocator;
    allocator.destroy(self);
}

/// A leftover persisted resolver handle would leak past its isolate.
fn clearPendingGotos(self: *Runtime) void {
    for (self.pending_gotos.items) |*entry| {
        entry.resolver.deinit();
    }
    self.pending_gotos.clearRetainingCapacity();
}

pub fn terminate(self: *Runtime) void {
    self.env.terminate();
}

pub fn cancelTerminate(self: *Runtime) void {
    self.env.cancelTerminate();
}

fn createContext(self: *Runtime) InitError!void {
    const context = self.env.createAgentContext(self.ctx_call_arena.allocator()) catch return error.RuntimeInitFailed;
    self.context = context;

    var ls: lp.js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;
    const global = local.globalObject();

    // Only `goto` is a global; the rest become page methods via `makePage`,
    // which reuses these `primitive_data` entries — so fill them all here.
    var i: usize = 0;
    for (std.enums.values(BrowserTool)) |t| {
        if (!t.isRecorded()) continue;
        self.primitive_data[i] = .{ .runtime = self, .tool = t };
        if (t == .goto) {
            const func = local.newRawCallback(primitiveCallback, &self.primitive_data[i]);
            _ = global.set(@tagName(t), func.toValue(), .{}) catch return error.RuntimeInitFailed;
        }
        i += 1;
    }
    try self.installConsole(local, global);
}

fn resetContext(self: *Runtime) void {
    const context = self.context orelse return;
    self.env.destroyContext(context);
    self.context = null;
}

fn installConsole(self: *Runtime, local: *const lp.js.Local, global: lp.js.Object) InitError!void {
    const console = local.newObject();
    for (std.enums.values(ConsoleMethod), 0..) |method, i| {
        self.console_data[i] = .{ .runtime = self, .method = method };
        const func = local.newRawCallback(consoleCallback, &self.console_data[i]);
        _ = console.set(@tagName(method), func.toValue(), .{}) catch return error.RuntimeInitFailed;
    }
    _ = global.set("console", console.toValue(), .{}) catch return error.RuntimeInitFailed;
}

/// Run script source in the agent context. Returns null on success; on a JS
/// compile/runtime exception returns a formatted error allocated in this
/// runtime's call arena and valid until deinit or the next run.
pub fn runSource(self: *Runtime, source: []const u8, name: []const u8) RunError!?[]const u8 {
    _ = self.call_arena.reset(.retain_capacity);

    var ls: lp.js.Local.Scope = undefined;
    self.context.?.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    var tc: lp.js.TryCatch = undefined;
    tc.init(local);
    defer tc.deinit();

    // Wrap in an async IIFE so the source can use top-level `await`. A top-level
    // `return <expr>` becomes the Promise's value, which we echo; a bare trailing
    // expression can't (`await` and a completion value are mutually exclusive in JS).
    const wrapped = std.fmt.allocPrint(self.call_arena.allocator(), "(async () => {{\n{s}\n}})()", .{source}) catch
        return try self.dupeError("out of memory");

    const completion = local.compileAndRun(wrapped, name) catch |err|
        return try self.formatTryCatch(tc, err);

    defer self.clearPendingGotos();

    const root = completion.toPromise();
    self.env.performIsolateMicrotasks();
    if (try self.driveToCompletion(local, root)) |interrupted| {
        return interrupted;
    }
    if (tc.hasCaught()) {
        return try self.formatTryCatch(tc, error.JsException);
    }

    switch (root.state()) {
        .fulfilled => self.printCompletion(root.result()),
        .rejected => return try self.formatRejection(root.result()),
        .pending => {}, // the script awaited something we can't settle
    }
    return null;
}

/// Format a caught JS exception (compile or run) into a run-arena message:
/// prefer the stack, else `line N: msg`.
fn formatTryCatch(self: *Runtime, tc: lp.js.TryCatch, err: anyerror) RunError![]const u8 {
    const arena = self.call_arena.allocator();
    const c = tc.caughtOrError(arena, err);
    if (c.stack) |stack| {
        if (stack.len > 0) return try self.dupeError(stack);
    }
    const exception = c.exception orelse "script failed";
    if (c.line) |line| {
        return std.fmt.allocPrint(arena, "line {d}: {s}", .{ line, exception }) catch return error.OutOfMemory;
    }
    return try self.dupeError(exception);
}

/// Drives the browser until the root Promise settles. Returns an interrupt
/// message (SIGINT/terminate), or null once it settles or stalls.
fn driveToCompletion(self: *Runtime, local: *const lp.js.Local, root: lp.js.Promise) RunError!?[]const u8 {
    while (root.state() == .pending) {
        if (self.session.isCancelled()) return try self.dupeError("cancelled");
        if (self.env.terminatePending()) return try self.dupeError("terminated");

        // Nothing in flight → the script awaits something we can't settle.
        if (self.pending_gotos.items.len == 0) break;

        var next_tick_ms: u32 = 0;
        {
            self.session.browser.env.isolate.enter();
            defer self.session.browser.env.isolate.exit();
            // A goto is in flight, so a page exists; `catch break` only guards
            // the impossible no-page case against an endless loop.
            var runner = self.session.runner(.{}) catch break;
            // A failed tick must not abort the wait; the deadline bounds it.
            const tick: TickResult = runner.tick(.{ .ms = 100 }) catch .{ .done = {} };
            next_tick_ms = switch (tick) {
                .ok => |ms| ms,
                .done => 0,
            };
        }

        self.resolveReadyGotos(local);
        self.env.performIsolateMicrotasks();

        // Honor the runner's pacing hint so a timer-only wait (no network I/O,
        // which `tick` would otherwise block on) doesn't busy-spin.
        if (next_tick_ms > 0) std.Thread.sleep(next_tick_ms * std.time.ns_per_ms);
    }
    return null;
}

fn formatRejection(self: *Runtime, value: lp.js.Value) RunError![]const u8 {
    const text = value.toStringSliceWithAlloc(self.call_arena.allocator()) catch
        return try self.dupeError("script failed");
    return try self.dupeError(text);
}

/// Echo a script's output — the value it `return`s from the async wrapper, so a
/// script ending in `return extract(...)` prints without `console.log`.
/// `undefined` — no `return`, or a bare trailing expression — stays silent.
fn printCompletion(self: *Runtime, value: lp.js.Value) void {
    if (value.isUndefined()) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const text = displayString(arena_state.allocator(), value) catch return;
    self.writeConsoleLine(.log, text);
}

fn primitiveCallback(info_handle: ?*const lp.js.Local.RawCallbackInfo) callconv(.c) void {
    const info = info_handle orelse return;
    var caller: lp.js.Caller = undefined;
    if (!caller.initFromHandle(info)) return;
    defer caller.deinit();
    const fci = lp.js.Caller.FunctionCallbackInfo{ .handle = info };
    const data: *PrimitiveData = @ptrCast(@alignCast(fci.getData() orelse return));
    data.runtime.invoke(&caller.local, data.tool, fci);
}

fn consoleCallback(info_handle: ?*const lp.js.Local.RawCallbackInfo) callconv(.c) void {
    const info = info_handle orelse return;
    var caller: lp.js.Caller = undefined;
    if (!caller.initFromHandle(info)) return;
    defer caller.deinit();
    const fci = lp.js.Caller.FunctionCallbackInfo{ .handle = info };
    const data: *ConsoleData = @ptrCast(@alignCast(fci.getData() orelse return));
    data.runtime.invokeConsole(&caller.local, data.method, fci);
}

const Fci = lp.js.Caller.FunctionCallbackInfo;

fn invoke(self: *Runtime, local: *const lp.js.Local, tool: BrowserTool, fci: Fci) void {
    // Owned, not shared: marshalling runs JS (`toJSON`) that can re-enter a
    // primitive; a shared arena would let the nested call reset ours mid-flight.
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argc: usize = fci.length();

    const args = self.buildArgs(arena, local, tool, fci, argc) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError("out of memory"),
        error.JsException => return,
        error.InvalidArguments => return self.throwTypeError("invalid arguments"),
    };

    if (tool == .goto) return self.invokeGoto(arena, local, fci, args);

    defer self.session._tool_frame_override = null;

    // Non-goto primitives are page methods; the receiver names the target frame.
    const frame_id = receiverFrameId(local, fci) orelse
        return self.throwError("this must be called as a method on a page returned by goto()");
    self.session._tool_frame_override = self.session.findFrameByFrameId(frame_id) orelse
        return self.throwError("page handle is no longer valid; the page was closed or replaced");

    const result = self.callTool(arena, tool, args) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError("out of memory"),
    };

    switch (result) {
        .ok => |text| switch (tool) {
            .extract => {
                const normalized = self.normalizeExtractReturnJson(arena, text) catch |err| switch (err) {
                    error.OutOfMemory => return self.throwError("out of memory"),
                };
                self.setReturnJson(local, fci, normalized);
            },
            else => fci.getReturnValue().set(local.newString(text).toValue()),
        },
        .fail => |message| self.throwError(message),
    }
}

/// Open a navigation; resolves a Page object whose methods target this page.
/// Concurrent gotos fork popups, so `Promise.all` fetches in parallel.
fn invokeGoto(
    self: *Runtime,
    arena: std.mem.Allocator,
    local: *const lp.js.Local,
    fci: Fci,
    args: ?std.json.Value,
) void {
    const resolver = local.createPromiseResolver();
    fci.getReturnValue().set(resolver.promise().toValue());

    const params = browser_tools.parseArgs(browser_tools.GotoParams, arena, args) catch |err| switch (err) {
        error.OutOfMemory => return resolver.rejectError("goto", .{ .generic_error = "out of memory" }),
        error.InvalidParams => return resolver.rejectError("goto", .{ .generic_error = "goto requires a url" }),
    };
    const url = params.url;
    const timeout = params.timeout orelse 10000;

    // Another goto in flight → fork a popup rather than tear down its page.
    const fork = self.pending_gotos.items.len != 0;
    const frame = frame: {
        self.session.browser.env.isolate.enter();
        defer self.session.browser.env.isolate.exit();
        break :frame browser_tools.openGotoFrame(self.session, self.registry, url, fork) catch
            return resolver.rejectError("goto", .{ .generic_error = "navigation failed to start" });
    };

    var global = resolver.persistOwned();
    self.pending_gotos.append(self.allocator, .{
        .frame_id = frame._frame_id,
        .resolver = global,
        .deadline_ms = std.time.milliTimestamp() + @as(i64, timeout),
    }) catch {
        global.deinit();
        return resolver.rejectError("goto", .{ .generic_error = "out of memory" });
    };
}

/// The Page object `goto` resolves: `__lpFrameId` plus a method for every
/// recorded tool except `goto`.
fn makePage(self: *Runtime, local: *const lp.js.Local, frame_id: u32) ?lp.js.Value {
    const obj = local.newObject();
    _ = obj.set("__lpFrameId", frame_id, .{}) catch return null;

    for (&self.primitive_data) |*data| {
        if (data.tool == .goto) continue;
        const func = local.newRawCallback(primitiveCallback, data);
        _ = obj.set(@tagName(data.tool), func.toValue(), .{}) catch return null;
    }
    return obj.toValue();
}

/// Frame id from a method's receiver (`this.__lpFrameId`), or null for a bare
/// call with no page receiver.
fn receiverFrameId(local: *const lp.js.Local, fci: Fci) ?u32 {
    const this: lp.js.Object = .{ .local = local, .handle = fci.getThis() };
    if (this.has("__lpFrameId") == false) return null;
    const prop = this.get("__lpFrameId") catch return null;
    if (!prop.isNumber()) return null;
    return prop.toU32() catch null;
}

/// Settle each pending goto: a reached load — or a soft timeout (the page may
/// still be usable) — resolves the page handle; a real navigation error
/// rejects. Runs on the script isolate where the resolvers live; the caller
/// drains microtasks after.
fn resolveReadyGotos(self: *Runtime, local: *const lp.js.Local) void {
    var i: usize = 0;
    while (i < self.pending_gotos.items.len) {
        const entry = &self.pending_gotos.items[i];
        const resolver = entry.resolver.local(local);

        const frame = self.session.findFrameByFrameId(entry.frame_id);
        const ls = if (frame) |f| f._load_state else .waiting;
        if (frame == null or frame.?._last_navigate_error != null) {
            resolver.rejectError("goto", .{ .generic_error = "navigation failed" });
        } else if (ls == .load or ls == .complete or std.time.milliTimestamp() >= entry.deadline_ms) {
            if (self.makePage(local, entry.frame_id)) |page| {
                resolver.resolve("goto", page);
            } else {
                resolver.rejectError("goto", .{ .generic_error = "internal: page alloc failed" });
            }
        } else {
            i += 1;
            continue;
        }

        var settled = self.pending_gotos.swapRemove(i);
        settled.resolver.deinit();
    }
}

fn invokeConsole(self: *Runtime, local: *const lp.js.Local, method: ConsoleMethod, fci: Fci) void {
    // Owned arena (see `invoke`): an argument's `toString` can re-enter a
    // primitive mid-loop and must not reset the buffer we're accumulating.
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    for (0..fci.length()) |i| {
        if (i > 0) aw.writer.writeByte(' ') catch return;
        const text = fci.getArg(@intCast(i), local).toStringSliceWithAlloc(arena) catch "<unprintable>";
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
    self.session.browser.env.isolate.enter();
    defer self.session.browser.env.isolate.exit();

    const result = browser_tools.call(arena, self.session, self.registry, @tagName(tool), args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FrameNotLoaded => return .{ .fail = "no page loaded - run goto(url) first" },
        else => return .{ .fail = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ @tagName(tool), @errorName(err) }) catch return error.OutOfMemory },
    };

    if (result.is_error) return .{ .fail = result.text };
    return .{ .ok = result.text };
}

const BuildArgsError = error{
    OutOfMemory,
    JsException,
    InvalidArguments,
};

fn buildArgs(
    self: *Runtime,
    arena: std.mem.Allocator,
    local: *const lp.js.Local,
    tool: BrowserTool,
    fci: Fci,
    argc: usize,
) BuildArgsError!?std.json.Value {
    return switch (tool) {
        .extract => try self.extractArgs(arena, local, fci, argc),
        else => try self.marshalArgs(arena, local, fci, argc, Schema.positionalFor(tool)),
    };
}

/// Marshals `tool(positionals…, options?)` into the args object `browser_tools.call`
/// expects: leading primitives bind to `positional` by index (a `null` omits its
/// field), a trailing object merges as options (conflict on a repeated field), and a
/// lone object passes through. Positionals stay opaque; the tool's parser types them.
fn marshalArgs(
    self: *Runtime,
    arena: std.mem.Allocator,
    local: *const lp.js.Local,
    fci: Fci,
    argc: usize,
    positional: []const []const u8,
) BuildArgsError!std.json.Value {
    const values = try arena.alloc(std.json.Value, argc);
    for (values, 0..) |*v, i| v.* = try self.argJson(arena, local, fci, @intCast(i));

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
    local: *const lp.js.Local,
    fci: Fci,
    argc: usize,
) BuildArgsError!std.json.Value {
    if (argc != 1) return error.InvalidArguments;
    const value = try self.argJson(arena, local, fci, 0);
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
    local: *const lp.js.Local,
    fci: Fci,
    index: u32,
) BuildArgsError!std.json.Value {
    return self.valueToJson(arena, fci.getArg(index, local));
}

fn valueToJson(_: *Runtime, arena: std.mem.Allocator, value: lp.js.Value) BuildArgsError!std.json.Value {
    const json = value.toJson(arena) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.JsException;
    if (std.mem.eql(u8, json, "undefined")) return error.InvalidArguments;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch error.InvalidArguments;
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

fn setReturnJson(self: *Runtime, local: *const lp.js.Local, fci: Fci, value: []const u8) void {
    if (value.len == 0) return; // leave the return value as undefined
    const parsed = local.parseJSON(value) catch return self.throwError("extract returned invalid JSON");
    fci.getReturnValue().set(parsed);
}

fn throwError(self: *Runtime, message: []const u8) void {
    _ = self.env.isolate.throwException(self.env.isolate.createError(message));
}

fn throwTypeError(self: *Runtime, message: []const u8) void {
    _ = self.env.isolate.throwException(self.env.isolate.createTypeError(message));
}

/// Display form for the script's completion value: objects and arrays as JSON
/// (plain coercion gives a useless `[object Object]`), every other value via
/// `toString`. Falls back to coercion when JSON.stringify fails (e.g. a circular
/// reference) — the `TryCatch` swallows that throw on `deinit`.
fn displayString(arena: std.mem.Allocator, value: lp.js.Value) ![]const u8 {
    if (value.isObject()) {
        var tc: lp.js.TryCatch = undefined;
        tc.init(value.local);
        defer tc.deinit();
        if (value.toJson(arena)) |json| return json else |_| {}
    }
    return value.toStringSliceWithAlloc(arena);
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
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (typeof page !== "object" || page === null) throw new Error("goto should resolve a page object: " + page);
        \\const text = page.evaluate("document.getElementById('btn').textContent");
        \\if (text !== "Click Me") throw new Error("evaluate ran in the wrong context: " + text);
    );

    const frame = testing.test_session.currentFrame().?;
    try testing.expect(std.mem.indexOf(u8, frame.url, "/src/browser/tests/mcp_actions.html") != null);
}

test "agent script runtime: extract returns a JavaScript object" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
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
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
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
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (typeof page !== "object" || page === null) throw new Error("strict-mode goto failed: " + page);
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
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
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
        \\await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
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
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (page.evaluate("typeof goto") !== "undefined") throw new Error("agent primitive leaked to page evaluate");
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
        \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
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
        \\let page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html", { timeout: 5000 });
        \\if (typeof page !== "object" || page === null) throw new Error("two-arg goto failed: " + page);
        \\// waitForState: single required param, positional like waitForSelector.
        \\if (!page.waitForState("load").includes("reached")) throw new Error("waitForState positional failed");
        \\// Object form still works.
        \\page = await goto({ url: "http://localhost:9582/src/browser/tests/mcp_actions.html", timeout: 5000 });
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
            \\await goto("http://localhost:9582/src/browser/tests/mcp_actions.html", { url: "http://other" });
        , "agent-runtime-conflict.js")).?;
        try testing.expect(std.mem.indexOf(u8, message, "invalid arguments") != null);
    }

    // More positionals than the tool has fields throws.
    {
        const message = (try runtime.runSource(
            \\const page = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
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

test "agent script runtime: parallel goto fetches concurrent pages, read per page object" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    // Two gotos in flight at once open distinct frames (root + popup) that load
    // concurrently in one Page; each is read back through the Page object goto resolved.
    try runTestScript(runtime,
        \\const [a, b] = await Promise.all([
        \\  goto("http://localhost:9582/src/browser/tests/mcp_actions.html"),
        \\  goto("http://localhost:9582/src/browser/tests/runner/runner1.html"),
        \\]);
        \\if (typeof a !== "object" || typeof b !== "object") throw new Error("goto should resolve page objects");
        \\const da = a.extract({ btn: "#btn" });
        \\if (da.btn !== "Click Me") throw new Error("page a read wrong: " + JSON.stringify(da));
        \\const db = b.extract({ sel: "#sel1" });
        \\if (db.sel !== "selector-1-content") throw new Error("page b read wrong: " + JSON.stringify(db));
    );
}

test "agent script runtime: a stale page handle is a hard error" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    // The first page goes stale once the second (non-forked) goto replaces the
    // page; reading through it must throw, not silently hit the current page.
    const message = (try runtime.runSource(
        \\const a = await goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\await goto("http://localhost:9582/src/browser/tests/runner/runner1.html");
        \\a.extract({ btn: "#btn" });
    , "agent-runtime-stale-handle.js")).?;

    try testing.expect(std.mem.indexOf(u8, message, "no longer valid") != null);
}

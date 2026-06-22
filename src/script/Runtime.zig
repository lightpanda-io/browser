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

const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const CDPNode = @import("../cdp/Node.zig");
const Schema = @import("Schema.zig");

const v8 = lp.js.v8;

const Runtime = @This();

allocator: std.mem.Allocator,
app: *lp.App,
session: *lp.Session,
registry: *CDPNode.Registry,
env: lp.js.Env,
context: v8.Global,
has_context: bool,
call_arena: std.heap.ArenaAllocator,
primitive_data: [recorded_tool_count]PrimitiveData,
console_data: [std.enums.values(ConsoleMethod).len]ConsoleData,
/// Notified before each `console.*` line is written. The REPL uses it to
/// clear the live spinner so script output starts on a clean line instead
/// of colliding with the indicator; the line still goes to stdout/stderr.
console_observer: ?ConsoleObserver = null,

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
        .context = undefined,
        .has_context = false,
        .call_arena = .init(allocator),
        .primitive_data = undefined,
        .console_data = undefined,
    };
    errdefer self.call_arena.deinit();

    // Separate isolate from the page. The full `Env` is used only as an isolate
    // + terminate/microtask carrier; the agent context is bare (no WebAPIs).
    self.env = lp.js.Env.init(app, .{}) catch return error.RuntimeInitFailed;
    errdefer self.env.deinit();

    try self.createContext();
    errdefer self.resetContext();

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
    var hs: lp.js.HandleScope = undefined;
    hs.init(self.env.isolate);
    defer hs.deinit();

    const context = v8.v8__Context__New(self.env.isolate.handle, null, null) orelse
        return error.RuntimeInitFailed;
    v8.v8__Global__New(self.env.isolate.handle, context, &self.context);
    self.has_context = true;

    v8.v8__Context__Enter(context);
    defer v8.v8__Context__Exit(context);

    // The promise-reject callback every `Env` installs reads a browser `Context`
    // from embedder slot 1; this bare context has none. Pin the slot to null so
    // the callback no-ops instead of aligncasting garbage — the script body runs
    // inside an async wrapper, so unhandled rejections happen routinely.
    v8.v8__Context__SetAlignedPointerInEmbedderData(context, 1, null);

    const global = v8.v8__Context__Global(context) orelse return error.RuntimeInitFailed;

    // `Page` is the only global verb; `new Page()` attaches a method for each
    // recorded tool, reusing these `primitive_data` entries — so fill them here.
    var i: usize = 0;
    for (std.enums.values(BrowserTool)) |t| {
        if (!t.isRecorded()) continue;
        self.primitive_data[i] = .{ .runtime = self, .tool = t };
        i += 1;
    }
    try self.installFunction(context, global, "Page", pageConstructor, self);
    try self.installConsole(context, global);
}

fn resetContext(self: *Runtime) void {
    if (!self.has_context) return;
    v8.v8__Global__Reset(&self.context);
    self.env.isolate.notifyContextDisposed();
    self.has_context = false;
}

const Callback = *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void;

/// Install `callback` (carrying `data` as its `External`) under `name` on `object`.
fn installFunction(
    self: *Runtime,
    context: *const v8.Context,
    object: *const v8.Object,
    name: []const u8,
    callback: Callback,
    data: *anyopaque,
) InitError!void {
    const external = self.env.isolate.createExternal(data);
    const func = v8.v8__Function__New__DEFAULT2(context, callback, external) orelse
        return error.RuntimeInitFailed;
    try self.setObjectProperty(context, object, name, @ptrCast(func));
}

fn installConsole(
    self: *Runtime,
    context: *const v8.Context,
    global: *const v8.Object,
) InitError!void {
    const console = v8.v8__Object__New(self.env.isolate.handle) orelse
        return error.RuntimeInitFailed;

    for (std.enums.values(ConsoleMethod), 0..) |method, i| {
        self.console_data[i] = .{ .runtime = self, .method = method };
        try self.installFunction(context, console, @tagName(method), consoleCallback, &self.console_data[i]);
    }

    try setObjectProperty(self, context, global, "console", @ptrCast(console));
}

fn setObjectProperty(
    self: *Runtime,
    context: *const v8.Context,
    object: *const v8.Object,
    name: []const u8,
    value: *const v8.Value,
) InitError!void {
    var out: v8.MaybeBool = undefined;
    v8.v8__Object__Set(
        object,
        context,
        @ptrCast(self.env.isolate.initStringHandle(name)),
        value,
        &out,
    );
    if (!out.has_value or !out.value) return error.RuntimeInitFailed;
}

/// Run script source in the agent context. Returns null on success; on a JS
/// compile/runtime exception returns a formatted error allocated in this
/// runtime's call arena and valid until deinit or the next run.
pub fn runSource(self: *Runtime, source: []const u8, name: []const u8) RunError!?[]const u8 {
    _ = self.call_arena.reset(.retain_capacity);

    var hs: lp.js.HandleScope = undefined;
    hs.init(self.env.isolate);
    defer hs.deinit();

    const context: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.context, self.env.isolate.handle) orelse
        return try self.dupeError("agent script context is not available"));
    v8.v8__Context__Enter(context);
    defer v8.v8__Context__Exit(context);

    var try_catch: v8.TryCatch = undefined;
    v8.v8__TryCatch__CONSTRUCT(&try_catch, self.env.isolate.handle);
    defer v8.v8__TryCatch__DESTRUCT(&try_catch);

    const script_name = self.env.isolate.initStringHandle(name);
    // Wrap in an async IIFE so the source can use top-level `await` (e.g.
    // `await page.goto(...)`). The wrapper evaluates to a Promise; a top-level
    // `return <expr>` becomes that Promise's value, which we echo. (A bare
    // trailing expression no longer auto-prints — `await` and a script
    // completion value are mutually exclusive in JS.)
    const wrapped = std.fmt.allocPrint(self.call_arena.allocator(), "(async () => {{\n{s}\n}})()", .{source}) catch
        return try self.dupeError("out of memory");
    const script_source = self.env.isolate.initStringHandle(wrapped);

    var origin: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT(&origin, script_name);

    var compiler_source: v8.ScriptCompilerSource = undefined;
    v8.v8__ScriptCompiler__Source__CONSTRUCT2(script_source, &origin, null, &compiler_source);
    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&compiler_source);

    const script = v8.v8__ScriptCompiler__Compile(
        context,
        &compiler_source,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse return try self.formatCaught(context, &try_catch, "compile failed");

    const completion = v8.v8__Script__Run(script, context) orelse
        return try self.formatCaught(context, &try_catch, "script failed");

    // `goto` runs synchronously and resolves its Promise before returning, so a
    // single microtask drain settles the whole `await` chain — no event-loop
    // driver. (Truly-async navigation is a later change.)
    const root: *const v8.Promise = @ptrCast(completion);
    self.env.performIsolateMicrotasks();
    if (v8.v8__TryCatch__HasCaught(&try_catch)) {
        return try self.formatCaught(context, &try_catch, "script failed");
    }

    // A still-pending root means the script awaited something we can't settle
    // (no async navigation is in flight) — stay silent.
    const state = promiseState(root);
    if (state != v8.kFulfilled and state != v8.kRejected) return null;
    const completion_value = v8.v8__Promise__Result(root) orelse return null;
    if (state == v8.kRejected) return try self.formatRejection(context, completion_value);
    self.printCompletion(context, completion_value);
    return null;
}

/// `v8__Promise__State` returns the `c_uint` `PromiseState`, but the `k*`
/// constants are `c_int`; normalize so comparisons and switches type-check.
fn promiseState(promise: *const v8.Promise) c_int {
    return @intCast(v8.v8__Promise__State(promise));
}

/// Format a script's rejection reason into a run-arena message. Prefers a thrown
/// Error's `.message` so the caller's own "Error:" label isn't doubled
/// (`Value.toString` on an Error yields "Error: <message>").
fn formatRejection(self: *Runtime, context: *const v8.Context, reason: *const v8.Value) RunError![]const u8 {
    const value = self.errorMessage(context, reason) orelse reason;
    const text = self.valueToString(self.call_arena.allocator(), context, value) catch
        return try self.dupeError("script failed");
    return try self.dupeError(text);
}

/// The `.message` of a thrown Error (a string), or null when `reason` is not an
/// Error-like object — in which case the caller stringifies the value itself.
fn errorMessage(self: *Runtime, context: *const v8.Context, reason: *const v8.Value) ?*const v8.Value {
    if (!v8.v8__Value__IsObject(reason)) return null;
    const key: *const v8.Value = @ptrCast(self.env.isolate.initStringHandle("message"));
    const message = v8.v8__Object__Get(@ptrCast(reason), context, key) orelse return null;
    return if (v8.v8__Value__IsString(message)) message else null;
}

/// Echo a script's output — the value it `return`s from the async wrapper, so a
/// script ending in `return page.extract(...)` prints without `console.log`.
/// `undefined` — no `return`, or a bare trailing expression — stays silent.
fn printCompletion(self: *Runtime, context: *const v8.Context, value: *const v8.Value) void {
    if (v8.v8__Value__IsUndefined(value)) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const text = self.displayString(arena_state.allocator(), context, value) catch return;
    self.writeConsoleLine(.log, text);
}

/// Unwrap a callback's info handle and its `External` payload (the `*T` passed
/// to `installFunction`). Returns null — so the callback no-ops — if either is
/// missing.
fn callbackData(comptime T: type, info_handle: ?*const v8.FunctionCallbackInfo) ?struct { *const v8.FunctionCallbackInfo, *T } {
    const info = info_handle orelse return null;
    const raw_data = v8.v8__FunctionCallbackInfo__Data(info) orelse return null;
    const data: *T = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(raw_data)) orelse return null));
    return .{ info, data };
}

fn primitiveCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info, const data = callbackData(PrimitiveData, info_handle) orelse return;
    data.runtime.invoke(data.tool, info);
}

fn consoleCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info, const data = callbackData(ConsoleData, info_handle) orelse return;
    data.runtime.invokeConsole(data.method, info);
}

fn pageConstructor(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info, const self = callbackData(Runtime, info_handle) orelse return;
    self.construct(info);
}

fn closeCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info, const self = callbackData(Runtime, info_handle) orelse return;
    self.invokeClose(info);
}

/// `new Page()`: attach a method for every recorded tool (including `goto`) plus
/// `close`. `__lpFrameId` is left unset until the first `goto` navigates the page.
fn construct(self: *Runtime, info: *const v8.FunctionCallbackInfo) void {
    if (!v8.v8__FunctionCallbackInfo__IsConstructCall(info)) {
        return self.throwTypeError("Page must be called with new");
    }
    const context = v8.v8__Isolate__GetCurrentContext(self.env.isolate.handle) orelse
        return self.throwError("internal: missing callback context");
    const this = v8.v8__FunctionCallbackInfo__This(info) orelse
        return self.throwError("internal: missing receiver");

    for (&self.primitive_data) |*data| {
        self.installFunction(context, this, @tagName(data.tool), primitiveCallback, data) catch
            return self.throwError("failed to construct page");
    }
    self.installFunction(context, this, "close", closeCallback, self) catch
        return self.throwError("failed to construct page");
}

/// Property carrying a page handle's claim on a live frame. Numeric while the
/// page is navigated; absent/undefined once never-navigated or closed.
const frame_id_key = "__lpFrameId";

/// `page.close()`: stale the wrapper so later method calls error. A single
/// synchronous page has no popups to free; the active page is reclaimed on the
/// next `goto` or at script end.
fn invokeClose(self: *Runtime, info: *const v8.FunctionCallbackInfo) void {
    const context = v8.v8__Isolate__GetCurrentContext(self.env.isolate.handle) orelse return;
    const this = v8.v8__FunctionCallbackInfo__This(info) orelse return;
    self.setObjectProperty(context, this, frame_id_key, self.env.isolate.initUndefined()) catch {};
}

fn invoke(self: *Runtime, tool: BrowserTool, info: *const v8.FunctionCallbackInfo) void {
    // Owned, not shared: marshalling runs JS (`toJSON`) that can re-enter a
    // primitive; a shared arena would let the nested call reset ours mid-flight.
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const context = v8.v8__Isolate__GetCurrentContext(self.env.isolate.handle) orelse {
        self.throwError("internal: missing callback context");
        return;
    };

    const args = self.buildArgs(arena, context, tool, info) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError("out of memory"),
        error.JsException => return,
        error.InvalidArguments => return self.throwTypeError("invalid arguments"),
    };

    // `goto` is the one async-shaped primitive: it returns a Promise (resolved
    // synchronously once the blocking navigation settles).
    if (tool == .goto) return self.invokeGoto(arena, context, info, args);

    // Other primitives are page methods. The receiver must be navigated, and —
    // since a single synchronous page has only one live frame — still be the
    // current one; a later `goto` (on any handle) replaces the page and stales
    // every other handle.
    const frame_id = self.receiverFrameId(context, info) orelse
        return self.throwError("page is not navigated or has been closed; call page.goto(url) first");
    const live = self.session.currentFrame();
    if (live == null or live.?._frame_id != frame_id) {
        return self.throwError("page handle is no longer valid; the page was closed or replaced");
    }

    const result = self.callTool(arena, tool, args) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError("out of memory"),
    };

    switch (result) {
        .ok => |text| switch (tool) {
            .extract => {
                const normalized = self.normalizeExtractReturnJson(arena, text) catch |err| switch (err) {
                    error.OutOfMemory => return self.throwError("out of memory"),
                };
                self.setReturnJson(context, info, normalized);
            },
            else => self.setReturnString(info, text),
        },
        .fail => |message| self.throwError(message),
    }
}

/// Navigate the receiver Page synchronously and hand back a resolved Promise of
/// the page object, so `await page.goto(url)` yields the page. The blocking
/// `goto` tool runs the navigation to completion before this returns; on success
/// the receiver's `__lpFrameId` is (re)bound to the freshly-loaded frame.
fn invokeGoto(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    args: ?std.json.Value,
) void {
    const resolver = v8.v8__Promise__Resolver__New(context) orelse
        return self.throwError("internal: resolver alloc failed");
    const promise = v8.v8__Promise__Resolver__GetPromise(resolver) orelse
        return self.throwError("internal: promise alloc failed");
    self.setReturnValue(info, @ptrCast(promise));

    const result = self.callTool(arena, .goto, args) catch |err| switch (err) {
        error.OutOfMemory => return self.rejectResolver(context, resolver, "out of memory"),
    };

    switch (result) {
        .ok => {
            const this = v8.v8__FunctionCallbackInfo__This(info) orelse
                return self.rejectResolver(context, resolver, "navigation failed");
            const frame = self.session.currentFrame() orelse
                return self.rejectResolver(context, resolver, "navigation failed");
            self.bindFrameId(context, this, frame._frame_id) catch
                return self.rejectResolver(context, resolver, "internal: page bind failed");
            self.resolveResolver(context, resolver, @ptrCast(this));
        },
        .fail => |message| self.rejectResolver(context, resolver, message),
    }
}

fn resolveResolver(_: *Runtime, context: *const v8.Context, resolver: *const v8.PromiseResolver, value: *const v8.Value) void {
    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Resolve(resolver, context, value, &out);
}

fn rejectResolver(self: *Runtime, context: *const v8.Context, resolver: *const v8.PromiseResolver, message: []const u8) void {
    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Reject(resolver, context, self.env.isolate.createError(message), &out);
}

/// Bind `__lpFrameId` on a page object to `frame_id` — the handle's claim on the
/// live frame, checked by `invoke` on every later method call.
fn bindFrameId(self: *Runtime, context: *const v8.Context, this: *const v8.Object, frame_id: u32) InitError!void {
    const value = v8.v8__Integer__NewFromUnsigned(self.env.isolate.handle, frame_id) orelse
        return error.RuntimeInitFailed;
    return self.setObjectProperty(context, this, frame_id_key, @ptrCast(value));
}

/// Frame id a method's receiver was bound to (`this.__lpFrameId`), or null when
/// the page was never navigated or has been closed.
fn receiverFrameId(self: *Runtime, context: *const v8.Context, info: *const v8.FunctionCallbackInfo) ?u32 {
    const this = v8.v8__FunctionCallbackInfo__This(info) orelse return null;
    const key: *const v8.Value = @ptrCast(self.env.isolate.initStringHandle(frame_id_key));
    const prop = v8.v8__Object__Get(this, context, key) orelse return null;
    if (!v8.v8__Value__IsNumber(prop)) return null;
    var out: v8.MaybeU32 = undefined;
    v8.v8__Value__Uint32Value(prop, context, &out);
    return if (out.has_value) out.value else null;
}

fn invokeConsole(self: *Runtime, method: ConsoleMethod, info: *const v8.FunctionCallbackInfo) void {
    // Owned arena (see `invoke`): an argument's `toString` can re-enter a
    // primitive mid-loop and must not reset the buffer we're accumulating.
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const context = v8.v8__Isolate__GetCurrentContext(self.env.isolate.handle) orelse return;
    const argc: usize = @intCast(v8.v8__FunctionCallbackInfo__Length(info));

    var aw: std.Io.Writer.Allocating = .init(arena);
    for (0..argc) |i| {
        if (i > 0) aw.writer.writeByte(' ') catch return;
        const value = v8.v8__FunctionCallbackInfo__INDEX(info, @intCast(i)) orelse continue;
        const text = self.valueToString(arena, context, value) catch "<unprintable>";
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
        error.FrameNotLoaded => return .{ .fail = "no page loaded - run page.goto(url) first" },
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
    context: *const v8.Context,
    tool: BrowserTool,
    info: *const v8.FunctionCallbackInfo,
) BuildArgsError!?std.json.Value {
    const argc: usize = @intCast(v8.v8__FunctionCallbackInfo__Length(info));
    return switch (tool) {
        .extract => try self.extractArgs(arena, context, info, argc),
        else => try self.marshalArgs(arena, context, info, argc, Schema.positionalFor(tool)),
    };
}

/// Marshals `tool(positionals…, options?)` into the args object `browser_tools.call`
/// expects: leading primitives bind to `positional` by index (a `null` omits its
/// field), a trailing object merges as options (conflict on a repeated field), and a
/// lone object passes through. Positionals stay opaque; the tool's parser types them.
fn marshalArgs(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    argc: usize,
    positional: []const []const u8,
) BuildArgsError!std.json.Value {
    const values = try arena.alloc(std.json.Value, argc);
    for (values, 0..) |*v, i| v.* = try self.argJson(arena, context, info, @intCast(i));

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
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    argc: usize,
) BuildArgsError!std.json.Value {
    if (argc != 1) return error.InvalidArguments;
    const value = try self.argJson(arena, context, info, 0);
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
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    index: u32,
) BuildArgsError!std.json.Value {
    const value = v8.v8__FunctionCallbackInfo__INDEX(info, @intCast(index)) orelse return error.InvalidArguments;
    return self.valueToJson(arena, context, value);
}

fn valueToJson(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    value: *const v8.Value,
) BuildArgsError!std.json.Value {
    const json_string = v8.v8__JSON__Stringify(context, value, null) orelse return error.JsException;
    const json = try self.stringToOwned(arena, json_string);
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

fn setReturnString(self: *Runtime, info: *const v8.FunctionCallbackInfo, value: []const u8) void {
    self.setReturnValue(info, @ptrCast(self.env.isolate.initStringHandle(value)));
}

fn setReturnJson(self: *Runtime, context: *const v8.Context, info: *const v8.FunctionCallbackInfo, value: []const u8) void {
    if (value.len == 0) {
        self.setReturnValue(info, self.env.isolate.initUndefined());
        return;
    }
    const json = self.env.isolate.initStringHandle(value);
    const parsed = v8.v8__JSON__Parse(context, json) orelse {
        self.throwError("extract returned invalid JSON");
        return;
    };
    self.setReturnValue(info, parsed);
}

fn setReturnValue(_: *Runtime, info: *const v8.FunctionCallbackInfo, value: *const v8.Value) void {
    var rv: v8.ReturnValue = undefined;
    v8.v8__FunctionCallbackInfo__GetReturnValue(info, &rv);
    v8.v8__ReturnValue__Set(rv, value);
}

fn throwError(self: *Runtime, message: []const u8) void {
    _ = v8.v8__Isolate__ThrowException(self.env.isolate.handle, self.env.isolate.createError(message));
}

fn throwTypeError(self: *Runtime, message: []const u8) void {
    _ = v8.v8__Isolate__ThrowException(self.env.isolate.handle, self.env.isolate.createTypeError(message));
}

fn formatCaught(
    self: *Runtime,
    context: *const v8.Context,
    try_catch: *const v8.TryCatch,
    fallback: []const u8,
) RunError![]const u8 {
    const arena = self.call_arena.allocator();
    if (v8.v8__TryCatch__StackTrace(try_catch, context)) |stack_value| {
        const stack = self.valueToString(arena, context, stack_value) catch "";
        if (stack.len > 0) return stack;
    }

    const exception = if (v8.v8__TryCatch__Exception(try_catch)) |exception_value|
        self.valueToString(arena, context, exception_value) catch fallback
    else
        fallback;

    const line: ?u32 = blk: {
        const msg = v8.v8__TryCatch__Message(try_catch) orelse break :blk null;
        const n = v8.v8__Message__GetLineNumber(msg, context);
        break :blk if (n < 0) null else @as(u32, @intCast(n));
    };
    if (line) |n| {
        return std.fmt.allocPrint(arena, "line {d}: {s}", .{ n, exception }) catch return error.OutOfMemory;
    }
    return try self.dupeError(exception);
}

fn valueToString(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    value: *const v8.Value,
) error{ OutOfMemory, JsException }![]const u8 {
    const string = v8.v8__Value__ToString(value, context) orelse return error.JsException;
    return self.stringToOwned(arena, string);
}

/// Display form for the script's completion value: objects and arrays as JSON
/// (plain coercion gives a useless `[object Object]`), every other value via that
/// coercion. Falls back to coercion when JSON.stringify yields no string — a
/// thrown circular reference, or a value (e.g. a function) that stringifies to
/// `undefined`; the nested TryCatch keeps such a throw from leaking into the
/// caller's scope.
fn displayString(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    value: *const v8.Value,
) error{ OutOfMemory, JsException }![]const u8 {
    if (v8.v8__Value__IsObject(value)) {
        var try_catch: v8.TryCatch = undefined;
        v8.v8__TryCatch__CONSTRUCT(&try_catch, self.env.isolate.handle);
        defer v8.v8__TryCatch__DESTRUCT(&try_catch);
        if (v8.v8__JSON__Stringify(context, value, null)) |json| {
            return self.stringToOwned(arena, json);
        }
    }
    return self.valueToString(arena, context, value);
}

fn stringToOwned(
    self: *Runtime,
    arena: std.mem.Allocator,
    string: *const v8.String,
) error{OutOfMemory}![]const u8 {
    const len: usize = @intCast(v8.v8__String__Utf8Length(string, self.env.isolate.handle));
    const buf = try arena.alloc(u8, len);
    const written = v8.v8__String__WriteUtf8(
        string,
        self.env.isolate.handle,
        buf.ptr,
        buf.len,
        v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8,
    );
    return buf[0..written];
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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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
    defer testing.test_session.closeAllPages();

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

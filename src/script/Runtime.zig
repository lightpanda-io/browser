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

    const global = v8.v8__Context__Global(context) orelse return error.RuntimeInitFailed;
    var i: usize = 0;
    for (std.enums.values(BrowserTool)) |t| {
        if (!t.isRecorded()) continue;
        self.primitive_data[i] = .{ .runtime = self, .tool = t };
        try self.installPrimitive(context, global, @tagName(t), &self.primitive_data[i]);
        i += 1;
    }
    try self.installConsole(context, global);
}

fn resetContext(self: *Runtime) void {
    if (!self.has_context) return;
    v8.v8__Global__Reset(&self.context);
    self.env.isolate.notifyContextDisposed();
    self.has_context = false;
}

fn installPrimitive(
    self: *Runtime,
    context: *const v8.Context,
    global: *const v8.Object,
    name: []const u8,
    data: *PrimitiveData,
) InitError!void {
    const external = self.env.isolate.createExternal(data);
    const func = v8.v8__Function__New__DEFAULT2(context, primitiveCallback, external) orelse
        return error.RuntimeInitFailed;
    var out: v8.MaybeBool = undefined;
    v8.v8__Object__Set(
        global,
        context,
        @ptrCast(self.env.isolate.initStringHandle(name)),
        @ptrCast(func),
        &out,
    );
    if (!out.has_value or !out.value) return error.RuntimeInitFailed;
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
        const external = self.env.isolate.createExternal(&self.console_data[i]);
        const func = v8.v8__Function__New__DEFAULT2(context, consoleCallback, external) orelse
            return error.RuntimeInitFailed;
        try setObjectProperty(self, context, console, @tagName(method), @ptrCast(func));
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
    const script_source = self.env.isolate.initStringHandle(source);

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

    // Explicit microtask policy: promise continuations only run once drained.
    self.env.performIsolateMicrotasks();
    if (v8.v8__TryCatch__HasCaught(&try_catch)) {
        return try self.formatCaught(context, &try_catch, "script failed");
    }

    self.printCompletion(context, completion);
    return null;
}

/// Echo a script's completion value (its last-evaluated expression) so a script
/// ending in `extract(...)` or a bare `results;` prints without `console.log`.
/// `undefined` — declarations, assignments, control flow — stays silent.
fn printCompletion(self: *Runtime, context: *const v8.Context, value: *const v8.Value) void {
    if (v8.v8__Value__IsUndefined(value)) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const text = self.displayString(arena_state.allocator(), context, value) catch return;
    self.writeConsoleLine(.log, text);
}

fn primitiveCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info = info_handle orelse return;
    const raw_data = v8.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *PrimitiveData = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(raw_data)) orelse return));
    data.runtime.invoke(data.tool, info);
}

fn consoleCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info = info_handle orelse return;
    const raw_data = v8.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *ConsoleData = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(raw_data)) orelse return));
    data.runtime.invokeConsole(data.method, info);
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
    context: *const v8.Context,
    tool: BrowserTool,
    info: *const v8.FunctionCallbackInfo,
) BuildArgsError!?std.json.Value {
    const argc: usize = @intCast(v8.v8__FunctionCallbackInfo__Length(info));

    return switch (tool) {
        .goto => try self.singleStringOrObject(arena, context, info, argc, "url"),
        .evaluate => try self.singleStringOrObject(arena, context, info, argc, "script"),
        .extract => try self.extractArgs(arena, context, info, argc),
        .waitForSelector => try self.singleStringOrObject(arena, context, info, argc, "selector"),
        .waitForScript => try self.singleStringOrObject(arena, context, info, argc, "script"),
        .press => try self.singleStringOrObject(arena, context, info, argc, "key"),
        .scroll => if (argc == 0) std.json.Value{ .object = .init(arena) } else try self.singleObject(arena, context, info, argc),
        .click, .fill, .hover, .selectOption, .setChecked => try self.singleObject(arena, context, info, argc),
        // Only recorded tools are installed, so the rest are unreachable; the
        // comptime guard makes a recorded tool left unmarshalled a compile error.
        inline else => |t| {
            if (comptime t.isRecorded()) @compileError("recorded tool ." ++ @tagName(t) ++ " has no marshalling in buildArgs");
            unreachable;
        },
    };
}

fn singleStringOrObject(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    argc: usize,
    field: []const u8,
) BuildArgsError!std.json.Value {
    if (argc != 1) return error.InvalidArguments;
    const value = try self.argJson(arena, context, info, 0);
    return switch (value) {
        .string => try objectWith(arena, field, value),
        .object => value,
        else => error.InvalidArguments,
    };
}

fn singleObject(
    self: *Runtime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    argc: usize,
) BuildArgsError!std.json.Value {
    if (argc != 1) return error.InvalidArguments;
    const value = try self.argJson(arena, context, info, 0);
    if (value != .object) return error.InvalidArguments;
    return value;
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
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const nav = goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (!nav.includes("Navigated")) throw new Error("unexpected goto result: " + nav);
        \\const text = evaluate("document.getElementById('btn').textContent");
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
        \\goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\const data = extract({
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
        \\const options = extract({
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
        \\const direct = extract([{ selector: "#sel option", limit: 1 }]);
        \\if (!Array.isArray(direct)) throw new Error("array schema should return an array");
        \\if (direct[0] !== "Option 1") throw new Error("unexpected direct array extract: " + direct[0]);
        \\const saveField = extract({ save: "#btn" });
        \\if (saveField.save !== "Click Me") throw new Error("top-level save field should be schema data");
        \\let rejectedSaveOption = false;
        \\try {
        \\  extract({ schema: { button: "#btn" }, save: "snap" });
        \\} catch (err) {
        \\  rejectedSaveOption = true;
        \\}
        \\if (!rejectedSaveOption) throw new Error("extract save option should be rejected");
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
        \\const nav = goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (!nav.includes("Navigated")) throw new Error("strict-mode goto failed: " + nav);
        \\const text = evaluate("document.getElementById('btn').textContent");
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
        \\let microtaskRan = false;
        \\Promise.resolve().then(() => { microtaskRan = true; });
        \\if (microtaskRan) throw new Error("microtask ran before the checkpoint");
    );

    try runTestScript(runtime,
        \\if (!microtaskRan) throw new Error("microtask did not run after the script");
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
        \\goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\// toJSON re-enters evaluate mid-marshal; the outer extract must still see "#btn".
        \\const data = extract({ button: { toJSON() { return evaluate("'#btn'"); } } });
        \\if (data.button !== "Click Me") throw new Error("re-entrant extract corrupted: " + JSON.stringify(data));
        \\// toString re-enters a primitive mid-loop; the console buffer must survive.
        \\let probed = 0;
        \\console.log("value", { toString() { probed += 1; return evaluate("'ok'"); } }, "tail");
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
        \\let counter = 1;
        \\if (typeof window !== "undefined") throw new Error("window leaked into agent runtime");
        \\if (typeof document !== "undefined") throw new Error("document leaked into agent runtime");
        \\goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\counter += 1;
        \\if (counter !== 2) throw new Error("agent global state did not persist");
    );

    try runTestScript(runtime,
        \\counter += 1;
        \\if (counter !== 3) throw new Error("agent global state was reset between scripts");
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
        \\goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (evaluate("typeof goto") !== "undefined") throw new Error("agent primitive leaked to page evaluate");
        \\if (evaluate("typeof agentOnly") !== "undefined") throw new Error("agent binding leaked to page evaluate");
        \\if (evaluate("typeof document") !== "object") throw new Error("page evaluate did not run in the page context");
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
        \\let marker = "before";
        \\goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\click({ selector: "#does-not-exist" });
        \\marker = "after";
    , "agent-runtime-failure.js")).?;

    try testing.expect(std.mem.indexOf(u8, message, "click") != null or
        std.mem.indexOf(u8, message, "NodeNotFound") != null or
        std.mem.indexOf(u8, message, "#does-not-exist") != null);

    try runTestScript(runtime,
        \\if (marker !== "before") throw new Error("script continued after tool failure");
    );
}

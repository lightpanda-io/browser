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

const ScriptRuntime = @This();

allocator: std.mem.Allocator,
app: *lp.App,
session: *lp.Session,
registry: *CDPNode.Registry,
env: lp.js.Env,
context: v8.Global,
has_context: bool,
call_arena: std.heap.ArenaAllocator,
primitive_data: [primitive_specs.len]PrimitiveData,
console_data: [console_specs.len]ConsoleData,

const Primitive = enum {
    goto,
    eval,
    extract,
    click,
    fill,
    scroll,
    waitForSelector,
    waitForScript,
    hover,
    press,
    selectOption,
    setChecked,

    fn tool(self: Primitive) BrowserTool {
        return switch (self) {
            .goto => .goto,
            .eval => .eval,
            .extract => .extract,
            .click => .click,
            .fill => .fill,
            .scroll => .scroll,
            .waitForSelector => .waitForSelector,
            .waitForScript => .waitForScript,
            .hover => .hover,
            .press => .press,
            .selectOption => .selectOption,
            .setChecked => .setChecked,
        };
    }
};

const primitive_specs = [_]struct {
    primitive: Primitive,
    name: []const u8,
}{
    .{ .primitive = .goto, .name = "goto" },
    .{ .primitive = .eval, .name = "eval" },
    .{ .primitive = .extract, .name = "extract" },
    .{ .primitive = .click, .name = "click" },
    .{ .primitive = .fill, .name = "fill" },
    .{ .primitive = .scroll, .name = "scroll" },
    .{ .primitive = .waitForSelector, .name = "waitForSelector" },
    .{ .primitive = .waitForScript, .name = "waitForScript" },
    .{ .primitive = .hover, .name = "hover" },
    .{ .primitive = .press, .name = "press" },
    .{ .primitive = .selectOption, .name = "selectOption" },
    .{ .primitive = .setChecked, .name = "setChecked" },
};

const PrimitiveData = struct {
    runtime: *ScriptRuntime,
    primitive: Primitive,
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

const console_specs = [_]struct {
    method: ConsoleMethod,
    name: []const u8,
}{
    .{ .method = .debug, .name = "debug" },
    .{ .method = .@"error", .name = "error" },
    .{ .method = .info, .name = "info" },
    .{ .method = .log, .name = "log" },
    .{ .method = .warn, .name = "warn" },
};

const ConsoleData = struct {
    runtime: *ScriptRuntime,
    method: ConsoleMethod,
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
) InitError!*ScriptRuntime {
    const self = try allocator.create(ScriptRuntime);
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

    self.env = lp.js.Env.init(app, .{}) catch return error.RuntimeInitFailed;
    errdefer self.env.deinit();

    try self.createContext();
    errdefer self.resetContext();

    return self;
}

pub fn deinit(self: *ScriptRuntime) void {
    self.resetContext();
    self.env.deinit();
    self.call_arena.deinit();
    const allocator = self.allocator;
    allocator.destroy(self);
}

pub fn terminate(self: *ScriptRuntime) void {
    self.env.terminate();
}

pub fn cancelTerminate(self: *ScriptRuntime) void {
    self.env.cancelTerminate();
}

fn createContext(self: *ScriptRuntime) InitError!void {
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
    for (primitive_specs, 0..) |spec, i| {
        self.primitive_data[i] = .{ .runtime = self, .primitive = spec.primitive };
        try self.installPrimitive(context, global, spec.name, &self.primitive_data[i]);
    }
    try self.installConsole(context, global);
}

fn resetContext(self: *ScriptRuntime) void {
    if (!self.has_context) return;
    v8.v8__Global__Reset(&self.context);
    self.env.isolate.notifyContextDisposed();
    self.has_context = false;
}

fn installPrimitive(
    self: *ScriptRuntime,
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
    self: *ScriptRuntime,
    context: *const v8.Context,
    global: *const v8.Object,
) InitError!void {
    const console = v8.v8__Object__New(self.env.isolate.handle) orelse
        return error.RuntimeInitFailed;

    for (console_specs, 0..) |spec, i| {
        self.console_data[i] = .{ .runtime = self, .method = spec.method };
        const external = self.env.isolate.createExternal(&self.console_data[i]);
        const func = v8.v8__Function__New__DEFAULT2(context, consoleCallback, external) orelse
            return error.RuntimeInitFailed;
        try setObjectProperty(self, context, console, spec.name, @ptrCast(func));
    }

    try setObjectProperty(self, context, global, "console", @ptrCast(console));
}

fn setObjectProperty(
    self: *ScriptRuntime,
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
pub fn runSource(self: *ScriptRuntime, source: []const u8, name: []const u8) RunError!?[]const u8 {
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

    _ = v8.v8__Script__Run(script, context) orelse
        return try self.formatCaught(context, &try_catch, "script failed");

    return null;
}

fn primitiveCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info = info_handle orelse return;
    const raw_data = v8.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *PrimitiveData = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(raw_data)) orelse return));
    data.runtime.invoke(data.primitive, info);
}

fn consoleCallback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info = info_handle orelse return;
    const raw_data = v8.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *ConsoleData = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(raw_data)) orelse return));
    data.runtime.invokeConsole(data.method, info);
}

fn invoke(self: *ScriptRuntime, primitive: Primitive, info: *const v8.FunctionCallbackInfo) void {
    _ = self.call_arena.reset(.retain_capacity);

    const arena = self.call_arena.allocator();
    const context = v8.v8__Object__GetCreationContext(v8.v8__FunctionCallbackInfo__This(info) orelse {
        self.throwError("internal: missing callback receiver");
        return;
    }) orelse {
        self.throwError("internal: missing callback context");
        return;
    };

    const args = self.buildArgs(arena, context, primitive, info) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError("out of memory"),
        error.JsException => return,
        error.InvalidArguments => return self.throwTypeError("invalid arguments"),
    };

    const result = self.callTool(arena, primitive.tool(), args) catch |err| switch (err) {
        error.OutOfMemory => return self.throwError("out of memory"),
    };

    switch (result) {
        .ok => |text| switch (primitive) {
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

fn invokeConsole(self: *ScriptRuntime, method: ConsoleMethod, info: *const v8.FunctionCallbackInfo) void {
    _ = self.call_arena.reset(.retain_capacity);

    const arena = self.call_arena.allocator();
    const context = v8.v8__Object__GetCreationContext(v8.v8__FunctionCallbackInfo__This(info) orelse return) orelse return;
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

fn writeConsoleLine(_: *ScriptRuntime, method: ConsoleMethod, line: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (method.writesStderr()) {
        var file = std.fs.File.stderr();
        var writer = file.writer(&buf);
        writer.interface.print("{s}\n", .{line}) catch return;
        writer.interface.flush() catch return;
        return;
    }

    var file = std.fs.File.stdout();
    var writer = file.writer(&buf);
    writer.interface.print("{s}\n", .{line}) catch return;
    writer.interface.flush() catch return;
}

const PrimitiveResult = union(enum) {
    ok: []const u8,
    fail: []const u8,
};

fn callTool(
    self: *ScriptRuntime,
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
    self: *ScriptRuntime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    primitive: Primitive,
    info: *const v8.FunctionCallbackInfo,
) BuildArgsError!?std.json.Value {
    const argc: usize = @intCast(v8.v8__FunctionCallbackInfo__Length(info));

    return switch (primitive) {
        .goto => try self.singleStringOrObject(arena, context, info, argc, "url"),
        .eval => try self.singleStringOrObject(arena, context, info, argc, "script"),
        .extract => try self.extractArgs(arena, context, info, argc),
        .waitForSelector => try self.singleStringOrObject(arena, context, info, argc, "selector"),
        .waitForScript => try self.singleStringOrObject(arena, context, info, argc, "script"),
        .press => try self.singleStringOrObject(arena, context, info, argc, "key"),
        .scroll => if (argc == 0) std.json.Value{ .object = .init(arena) } else try self.singleObject(arena, context, info, argc),
        .click, .fill, .hover, .selectOption, .setChecked => try self.singleObject(arena, context, info, argc),
    };
}

fn singleStringOrObject(
    self: *ScriptRuntime,
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
    self: *ScriptRuntime,
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
    self: *ScriptRuntime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    argc: usize,
) BuildArgsError!std.json.Value {
    if (argc != 1) return error.InvalidArguments;
    const value = try self.argJson(arena, context, info, 0);
    switch (value) {
        .string => |str| return try objectWith(arena, "schema", .{
            .string = try normalizeExtractSchemaString(arena, str),
        }),
        .array => return try objectWith(arena, "schema", .{
            .string = try extractSchemaString(arena, value),
        }),
        .object => |obj| {
            if (obj.get("schema")) |schema| {
                if (obj.count() != 1) return error.InvalidArguments;
                return try objectWith(arena, "schema", .{
                    .string = try extractSchemaString(arena, schema),
                });
            }
            return try objectWith(arena, "schema", .{
                .string = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = obj }, .{}),
            });
        },
        else => return error.InvalidArguments,
    }
}

fn extractSchemaString(arena: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}![]const u8 {
    return switch (value) {
        .string => |str| normalizeExtractSchemaString(arena, str),
        .array => |arr| blk: {
            const body = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .array = arr }, .{});
            break :blk try std.fmt.allocPrint(arena, "{{\"__root\":{s}}}", .{body});
        },
        else => try std.json.Stringify.valueAlloc(arena, value, .{}),
    };
}

fn normalizeExtractSchemaString(arena: std.mem.Allocator, schema: []const u8) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, schema, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '[') return schema;
    return try std.fmt.allocPrint(arena, "{{\"__root\":{s}}}", .{schema});
}

fn argJson(
    self: *ScriptRuntime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    info: *const v8.FunctionCallbackInfo,
    index: u32,
) BuildArgsError!std.json.Value {
    const value = v8.v8__FunctionCallbackInfo__INDEX(info, @intCast(index)) orelse return error.InvalidArguments;
    return self.valueToJson(arena, context, value);
}

fn valueToJson(
    self: *ScriptRuntime,
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

fn normalizeExtractReturnJson(_: *ScriptRuntime, arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    if (value.len == 0) return value;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return value,
    };
    if (parsed != .object or parsed.object.count() != 1) return value;

    var it = parsed.object.iterator();
    const entry = it.next() orelse return value;
    if (entry.value_ptr.* != .array) return value;
    return try std.json.Stringify.valueAlloc(arena, entry.value_ptr.*, .{});
}

fn setReturnString(self: *ScriptRuntime, info: *const v8.FunctionCallbackInfo, value: []const u8) void {
    self.setReturnValue(info, @ptrCast(self.env.isolate.initStringHandle(value)));
}

fn setReturnJson(self: *ScriptRuntime, context: *const v8.Context, info: *const v8.FunctionCallbackInfo, value: []const u8) void {
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

fn setReturnValue(_: *ScriptRuntime, info: *const v8.FunctionCallbackInfo, value: *const v8.Value) void {
    var rv: v8.ReturnValue = undefined;
    v8.v8__FunctionCallbackInfo__GetReturnValue(info, &rv);
    v8.v8__ReturnValue__Set(rv, value);
}

fn throwError(self: *ScriptRuntime, message: []const u8) void {
    _ = v8.v8__Isolate__ThrowException(self.env.isolate.handle, self.env.isolate.createError(message));
}

fn throwTypeError(self: *ScriptRuntime, message: []const u8) void {
    _ = v8.v8__Isolate__ThrowException(self.env.isolate.handle, self.env.isolate.createTypeError(message));
}

fn formatCaught(
    self: *ScriptRuntime,
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
    self: *ScriptRuntime,
    arena: std.mem.Allocator,
    context: *const v8.Context,
    value: *const v8.Value,
) error{ OutOfMemory, JsException }![]const u8 {
    const string = v8.v8__Value__ToString(value, context) orelse return error.JsException;
    return self.stringToOwned(arena, string);
}

fn stringToOwned(
    self: *ScriptRuntime,
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

fn dupeError(self: *ScriptRuntime, message: []const u8) RunError![]const u8 {
    return self.call_arena.allocator().dupe(u8, message) catch error.OutOfMemory;
}

const testing = @import("../testing.zig");

fn runTestScript(runtime: *ScriptRuntime, source: []const u8) !void {
    if (try runtime.runSource(source, "agent-runtime-test.js")) |message| {
        std.debug.print("agent script failed:\n{s}\n", .{message});
        return error.AgentScriptFailed;
    }
}

fn terminateRuntimeSoon(runtime: *ScriptRuntime) void {
    std.Thread.sleep(10 * std.time.ns_per_ms);
    runtime.terminate();
}

test "agent script runtime: goto and eval dispatch through browser tools" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const nav = goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (!nav.includes("Navigated")) throw new Error("unexpected goto result: " + nav);
        \\const text = eval("document.getElementById('btn').textContent");
        \\if (text !== "Click Me") throw new Error("eval ran in the wrong context: " + text);
    );

    const frame = testing.test_session.currentFrame().?;
    try testing.expect(std.mem.indexOf(u8, frame.url, "/src/browser/tests/mcp_actions.html") != null);
}

test "agent script runtime: extract returns a JavaScript object" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
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
        \\if (!Array.isArray(options)) throw new Error("single array field should return an array");
        \\if (options[0].text !== "Option 1") throw new Error("unexpected unwrapped option text: " + options[0].text);
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

test "agent script runtime: terminate interrupts local JavaScript" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
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

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
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

test "agent script runtime: page eval cannot see agent primitives or bindings" {
    defer testing.reset();
    defer if (testing.test_session.hasPage()) testing.test_session.removePage();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
    defer runtime.deinit();

    try runTestScript(runtime,
        \\const agentOnly = "secret";
        \\goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\if (eval("typeof goto") !== "undefined") throw new Error("agent primitive leaked to page eval");
        \\if (eval("typeof agentOnly") !== "undefined") throw new Error("agent binding leaked to page eval");
        \\if (eval("typeof document") !== "object") throw new Error("page eval did not run in the page context");
    );
}

test "agent script runtime: console is available in agent context" {
    defer testing.reset();

    var registry = CDPNode.Registry.init(testing.allocator);
    defer registry.deinit();

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
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

    const runtime = try ScriptRuntime.init(testing.allocator, testing.test_app, testing.test_session, &registry);
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

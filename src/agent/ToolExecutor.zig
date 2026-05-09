const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const App = @import("../App.zig");
const CDPNode = @import("../cdp/Node.zig");
const browser_tools = lp.tools;

const Self = @This();

allocator: std.mem.Allocator,
app: *App,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
node_registry: CDPNode.Registry,
tool_schema_arena: std.heap.ArenaAllocator,
/// Schemas parsed once at init from `browser_tools.tool_defs`. The slice and
/// every JSON `Value` inside live in `tool_schema_arena`.
tools: []const zenai.provider.Tool,

pub fn init(allocator: std.mem.Allocator, app: *App) !*Self {
    const notification: *lp.Notification = try .init(allocator);
    errdefer notification.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .app = app,
        .notification = notification,
        .browser = undefined,
        .session = undefined,
        .node_registry = CDPNode.Registry.init(allocator),
        .tool_schema_arena = std.heap.ArenaAllocator.init(allocator),
        .tools = &.{},
    };

    self.tools = try buildTools(self.tool_schema_arena.allocator());

    try self.browser.init(app, .{}, null);
    errdefer self.browser.deinit();

    self.session = try self.browser.newSession(self.notification);
    return self;
}

fn buildTools(arena: std.mem.Allocator) ![]const zenai.provider.Tool {
    const tools = try arena.alloc(zenai.provider.Tool, browser_tools.tool_defs.len);
    for (browser_tools.tool_defs, 0..) |t, i| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, t.input_schema, .{});
        tools[i] = .{ .name = t.name, .description = t.description, .parameters = parsed };
    }
    return tools;
}

pub fn deinit(self: *Self) void {
    self.tool_schema_arena.deinit();
    self.node_registry.deinit();
    self.browser.deinit();
    self.notification.deinit();
    self.allocator.destroy(self);
}

pub const CallError = browser_tools.ToolError || error{InvalidJsonArguments};

/// Allocator backing the parsed tool schemas. Lives for the executor's
/// lifetime, so callers can hand back slices that need the same lifetime
/// (e.g. derived caches over `getTools` output).
pub fn schemaAllocator(self: *Self) std.mem.Allocator {
    return self.tool_schema_arena.allocator();
}

pub fn getCurrentUrl(self: *Self) []const u8 {
    return browser_tools.currentUrlOrPlaceholder(self.session);
}

/// Run a JavaScript expression and return the full result (text + error flag).
pub fn callEval(self: *Self, arena: std.mem.Allocator, script: []const u8) browser_tools.EvalResult {
    return browser_tools.evalScript(arena, self.session, &self.node_registry, script);
}

pub fn call(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) CallError![]const u8 {
    const arguments: ?std.json.Value = if (arguments_json.len > 0)
        std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch
            return error.InvalidJsonArguments
    else
        null;

    return self.callValue(arena, tool_name, arguments);
}

/// Like `call` but takes an already-parsed JSON value. Skips the
/// stringify+reparse for callers (e.g. PandaScript replay) that already
/// have a `std.json.Value`.
pub fn callValue(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments: ?std.json.Value) browser_tools.ToolError![]const u8 {
    return browser_tools.call(arena, self.session, &self.node_registry, tool_name, arguments);
}

pub fn extractText(self: *Self, arena: std.mem.Allocator, selector: []const u8) browser_tools.EvalResult {
    return browser_tools.extractText(arena, self.session, &self.node_registry, selector);
}

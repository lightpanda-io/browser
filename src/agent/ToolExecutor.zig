const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const App = @import("../App.zig");
const HttpClient = @import("../browser/HttpClient.zig");
const CDPNode = @import("../cdp/Node.zig");
const browser_tools = lp.tools;

const Self = @This();

allocator: std.mem.Allocator,
app: *App,
http_client: *HttpClient,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
node_registry: CDPNode.Registry,
tool_schema_arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, app: *App) !*Self {
    const http_client = try HttpClient.init(allocator, &app.network);
    errdefer http_client.deinit();

    const notification = try lp.Notification.init(allocator);
    errdefer notification.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var browser = try lp.Browser.init(app, .{ .http_client = http_client });
    errdefer browser.deinit();

    self.* = .{
        .allocator = allocator,
        .app = app,
        .http_client = http_client,
        .notification = notification,
        .browser = browser,
        .session = undefined,
        .node_registry = CDPNode.Registry.init(allocator),
        .tool_schema_arena = std.heap.ArenaAllocator.init(allocator),
    };

    self.session = try self.browser.newSession(self.notification);
    return self;
}

pub fn deinit(self: *Self) void {
    self.tool_schema_arena.deinit();
    self.node_registry.deinit();
    self.browser.deinit();
    self.notification.deinit();
    self.http_client.deinit();
    self.allocator.destroy(self);
}

pub const CallError = browser_tools.ToolError || error{ InvalidJsonArguments, OutOfMemory };

pub fn getTools(self: *Self) ![]const zenai.provider.Tool {
    const arena = self.tool_schema_arena.allocator();
    const tools = try arena.alloc(zenai.provider.Tool, browser_tools.tool_defs.len);
    for (browser_tools.tool_defs, 0..) |t, i| {
        const parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            t.input_schema,
            .{},
        );
        tools[i] = .{
            .name = t.name,
            .description = t.description,
            .parameters = parsed,
        };
    }
    return tools;
}

pub fn getCurrentUrl(self: *Self) []const u8 {
    const page = self.session.currentPage() orelse return "(no page loaded)";
    return page.url;
}

pub fn call(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) CallError![]const u8 {
    const arguments = if (arguments_json.len > 0) blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, arena, arguments_json, .{}) catch
            return error.InvalidJsonArguments;
        break :blk parsed.value;
    } else null;

    return browser_tools.call(self.session, &self.node_registry, arena, tool_name, arguments);
}

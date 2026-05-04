const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const Agent = @import("Agent.zig");
const browser_tools = lp.tools;
const protocol = @import("../mcp/protocol.zig");
const Transport = @import("../mcp/Transport.zig");

const log = lp.log;
const Self = @This();

/// MCP server exposing a single `task` tool backed by an `Agent`.
allocator: std.mem.Allocator,
agent: *Agent,
transport: Transport,

const task_tool_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "task": { "type": "string", "description": "Natural-language instruction for the agent to execute against a headless browser." },
    \\    "attachments": { "type": "array", "items": { "type": "string" }, "description": "Optional local file paths to attach to the request (image/PDF/text). Paths must be relative to lightpanda's working directory and must not contain '..' segments. Provider must accept attachments." },
    \\    "fresh": { "type": "boolean", "description": "If true, start the task from a fresh browser session with no cookies and no current page." }
    \\  },
    \\  "required": ["task"]
    \\}
);

const task_tool = protocol.Tool{
    .name = "task",
    .description = "Delegate a high-level browsing task to the Lightpanda agent. The agent drives the browser internally with multiple tool calls and returns only the final answer, so the caller's context is not polluted with intermediate tree dumps, clicks, or scrolls.",
    .inputSchema = task_tool_schema,
};

pub fn init(allocator: std.mem.Allocator, app: *App, opts: lp.Config.Agent, writer: *std.io.Writer) !*Self {
    const agent = try Agent.init(allocator, app, opts);
    errdefer agent.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .agent = agent,
        .transport = .init(allocator, writer),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.transport.deinit();
    self.agent.deinit();
    self.allocator.destroy(self);
}

pub fn handleInitialize(self: *Self, req: protocol.Request) !void {
    const id = req.id orelse return;
    try self.transport.sendResult(id, protocol.InitializeResult{
        .protocolVersion = @tagName(protocol.Version.default),
        .capabilities = .{ .tools = .{} },
        .serverInfo = .{ .name = "lightpanda-agent", .version = "0.1.0" },
    });
}

pub fn handleToolList(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    _ = arena;
    const id = req.id orelse return;
    try self.transport.sendResult(id, .{ .tools = &[_]protocol.Tool{task_tool} });
}

pub fn handleToolCall(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    const id = req.id orelse return;
    const params = req.params orelse return self.transport.sendError(id, .InvalidParams, "Missing params");

    const CallParams = struct {
        name: []const u8,
        arguments: ?std.json.Value = null,
    };
    const call_params = std.json.parseFromValueLeaky(CallParams, arena, params, .{ .ignore_unknown_fields = true }) catch
        return self.transport.sendError(id, .InvalidParams, "Invalid params");

    if (!std.mem.eql(u8, call_params.name, task_tool.name)) {
        return self.transport.sendError(id, .MethodNotFound, "Tool not found");
    }

    const args_value = call_params.arguments orelse
        return self.transport.sendError(id, .InvalidParams, "Missing arguments");

    const TaskArgs = struct {
        task: []const u8,
        attachments: ?[]const []const u8 = null,
        fresh: ?bool = null,
    };
    const args = std.json.parseFromValueLeaky(TaskArgs, arena, args_value, .{ .ignore_unknown_fields = true }) catch
        return self.transport.sendError(id, .InvalidParams, "Invalid task arguments");

    // The MCP client is untrusted: refuse paths that could escape the
    // working directory before they reach `std.fs.cwd().openFile`.
    if (args.attachments) |paths| {
        for (paths) |p| {
            if (!isAttachmentPathSafe(p)) {
                log.warn(.mcp, "rejected unsafe attachment path", .{ .path = p });
                return self.transport.sendError(
                    id,
                    .InvalidParams,
                    "attachment paths must be relative and must not contain '..'",
                );
            }
        }
    }

    if (args.fresh orelse false) {
        self.agent.tool_executor.resetSession() catch |err| {
            log.err(.mcp, "fresh session reset failed", .{ .err = err });
            return self.sendErrorResult(id, "Failed to start a fresh browser session");
        };
    }

    const answer = self.agent.runOneTask(args.task, args.attachments) catch |err| {
        log.err(.mcp, "agent task failed", .{ .err = err });
        return self.sendErrorResult(id, @errorName(err));
    };

    const text = answer orelse return self.sendErrorResult(id, "(no response from model)");

    const content = [_]protocol.TextContent([]const u8){.{ .text = text }};
    try self.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn sendErrorResult(self: *Self, id: std.json.Value, msg: []const u8) !void {
    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try self.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = true });
}

/// Reject paths that an untrusted MCP client could use to escape the
/// working directory: absolute paths and any path with a `..` segment.
/// Operator-controlled symlinks already inside CWD are out of scope —
/// the threat we close here is "client supplies an arbitrary string".
fn isAttachmentPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

test "isAttachmentPathSafe accepts relative paths without traversal" {
    try std.testing.expect(isAttachmentPathSafe("foo.txt"));
    try std.testing.expect(isAttachmentPathSafe("./foo.txt"));
    try std.testing.expect(isAttachmentPathSafe("sub/foo.txt"));
    try std.testing.expect(isAttachmentPathSafe("a/b/c/d.png"));
    try std.testing.expect(isAttachmentPathSafe("dir/file.with..dots"));
}

test "isAttachmentPathSafe rejects absolute paths and traversal" {
    try std.testing.expect(!isAttachmentPathSafe(""));
    try std.testing.expect(!isAttachmentPathSafe("/etc/passwd"));
    try std.testing.expect(!isAttachmentPathSafe("/foo"));
    try std.testing.expect(!isAttachmentPathSafe("../etc/passwd"));
    try std.testing.expect(!isAttachmentPathSafe("..\\windows\\system32"));
    try std.testing.expect(!isAttachmentPathSafe("sub/../etc/passwd"));
    try std.testing.expect(!isAttachmentPathSafe("sub/.."));
    try std.testing.expect(!isAttachmentPathSafe(".."));
}

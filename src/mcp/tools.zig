const std = @import("std");

const lp = @import("lightpanda");
const js = lp.js;
const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;

const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const McpTool = protocol.Tool;

/// Convert browser tool_defs to MCP wire-protocol tools (comptime).
/// Tool identity comes from the `BrowserTool` tag — `tool_defs` only
/// carries the LLM-facing description and JSON schema.
const browser_tool_list = blk: {
    const fields = @typeInfo(BrowserTool).@"enum".fields;
    var tools: [fields.len]McpTool = undefined;
    for (browser_tools.tool_defs, fields, 0..) |td, f, i| {
        tools[i] = .{
            .name = f.name,
            .title = td.summary,
            .description = td.description,
            .inputSchema = td.input_schema,
            .annotations = annotations(@field(BrowserTool, f.name)),
        };
    }
    break :blk tools;
};

const read_only: protocol.ToolAnnotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true, .openWorldHint = false };

/// Exhaustive so a new tool must classify itself. Read-only means the call
/// cannot change page or session state: navigation writes cookies and
/// storage, and waiting lets page scripts run, so neither qualifies.
fn annotations(tool: BrowserTool) protocol.ToolAnnotations {
    return switch (tool) {
        .nodeDetails, .findElement, .getUrl, .getCookies, .getEnv, .extract => read_only,
        // Drains the buffer: a second call returns something else.
        .consoleLogs => .{ .readOnlyHint = true, .destructiveHint = false, .openWorldHint = false },
        .goto, .search, .markdown, .html, .links, .tree, .interactiveElements, .structuredData, .detectForms => .{ .destructiveHint = false, .idempotentHint = true },
        // Overwrites `path` when given.
        .screenshot => .{ .idempotentHint = true },
        .waitForSelector, .waitForScript, .waitForState => .{ .destructiveHint = false, .idempotentHint = true, .openWorldHint = false },
        .evaluate, .click, .press => .{},
        .fill, .selectOption, .setChecked, .hover => .{ .destructiveHint = false, .idempotentHint = true, .openWorldHint = false },
        .scroll => .{ .destructiveHint = false, .openWorldHint = false },
    };
}

const save_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Relative path (no '..' segments) to write the script to. Created or overwritten. The response reports the absolute location." },
    \\    "script": { "type": "string", "description": "The JavaScript agent script to write. Synthesize it per this tool's description." }
    \\  },
    \\  "required": ["path", "script"]
    \\}
);

const session_new_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": { "type": "string", "description": "Optional id for the new session. Omit to get an auto-generated one. Reusing an existing id returns that session (a way to share one browsing context between agents)." }
    \\  }
    \\}
);

const session_id_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "id": { "type": "string", "description": "The session id." }
    \\  },
    \\  "required": ["id"]
    \\}
);

const extra_tools = [_]McpTool{
    .{
        .name = "save",
        .title = "Save the session as an agent script",
        .annotations = .{ .idempotentHint = true, .openWorldHint = false },
        .description = "Save the session as a reusable Lightpanda agent script. You hold the conversation, so synthesize the `script` yourself — `const page = new Page(); await page.goto(url);` then call the builtins you used as tools (extract, click, fill, …) as methods on `page` with the same object arguments. Keep `$LP_*` placeholders; never inline a resolved secret.\n\n" ++ browser_tools.save_synthesis_prompt ++ "\n\n" ++ browser_tools.save_script_rules,
        .inputSchema = save_schema,
    },
    .{
        .name = "session_new",
        .title = "Create an isolated browser session",
        .annotations = .{ .destructiveHint = false, .idempotentHint = true, .openWorldHint = false },
        .description = "Create a new isolated browser session (its own page, cookies and memory) and return its id. Use it to give a separate agent its own browsing context, or to obtain an id to share. Pass that id back as the `Mcp-Session-Id` header to route calls to it.",
        .inputSchema = session_new_schema,
    },
    .{
        .name = "session_list",
        .title = "List browser sessions",
        .annotations = read_only,
        .description = "List the active browser sessions with their id and current URL. The `default` session always exists.",
        .inputSchema = browser_tools.minify("{ \"type\": \"object\", \"properties\": {} }"),
    },
    .{
        .name = "session_close",
        .title = "Close a browser session",
        .annotations = .{ .openWorldHint = false },
        .description = "Close a browser session, freeing its page and memory. The `default` session cannot be closed.",
        .inputSchema = session_id_schema,
    },
};

const all_tools = browser_tool_list ++ extra_tools;

/// Tools that bypass the browser-tool dispatch and have their own handlers.
const ExtraTool = enum {
    save,
    session_new,
    session_list,
    session_close,
};

pub fn handleList(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    _ = arena;
    const id = req.id orelse return;
    try server.sendResult(id, .{ .tools = &all_tools });
}

pub fn handleCall(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    const id = req.id orelse return;
    const params = req.params orelse return server.sendError(id, .InvalidParams, "Missing params");

    const call_params = browser_tools.parseValue(protocol.CallParams, arena, params) catch {
        return server.sendError(id, .InvalidParams, "Invalid params");
    };

    if (std.meta.stringToEnum(ExtraTool, call_params.name)) |tool| {
        return switch (tool) {
            .save => handleSave(server, arena, id, call_params.arguments),
            .session_new => handleSessionNew(server, arena, id, call_params.arguments),
            .session_list => handleSessionList(server, arena, id),
            .session_close => handleSessionClose(server, arena, id, call_params.arguments),
        };
    }

    return dispatchBrowserTool(server, arena, id, call_params.name, call_params.arguments);
}

fn dispatchBrowserTool(
    server: *Server,
    arena: std.mem.Allocator,
    id: std.json.Value,
    name: []const u8,
    arguments: ?std.json.Value,
) !void {
    const tool = std.meta.stringToEnum(BrowserTool, name) orelse {
        return server.sendError(id, .MethodNotFound, "Tool not found");
    };

    const active = server.active_session;
    const result = browser_tools.call(arena, active.session, &active.registry, name, arguments, .{ .inline_image = true }) catch |err| {
        // evaluate/extract surface failures in-band so the LLM can self-correct;
        // other tools' operational failures are protocol-level.
        if (surfacesErrorInBand(tool)) {
            return sendToolResultText(server, id, @errorName(err), true);
        }
        const code: protocol.ErrorCode = switch (err) {
            error.FrameNotLoaded => .FrameNotLoaded,
            error.NodeNotFound, error.InvalidParams => .InvalidParams,
            error.Cancelled => .Cancelled,
            error.Timeout => .Timeout,
            error.NavigationFailed, error.InternalError, error.OutOfMemory => .InternalError,
        };
        return server.sendError(id, code, browser_tools.errorMessage(err));
    };

    if (result.image) |image| {
        const Content = struct { protocol.ImageContent(lp.screenshot.Prepared), protocol.TextContent([]const u8) };
        return server.sendResult(id, protocol.CallToolResult(Content){
            .content = .{ .{ .data = image, .mimeType = "image/png" }, .{ .text = result.text } },
            .isError = result.is_error,
        });
    }
    try sendToolResultText(server, id, result.text, result.is_error);
}

fn surfacesErrorInBand(tool: BrowserTool) bool {
    return tool == .evaluate or tool == .extract;
}

fn handleSave(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Args = struct { path: []const u8, script: []const u8 };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { path: string, script: string }");
    };

    if (!browser_tools.isPathSafe(args.path)) {
        return sendErrorContent(server, id, browser_tools.unsafe_path_message);
    }

    // The client never sees resolved secrets, but scrub any literal LP_* value
    // back to its `$LP_*` placeholder as a safety net before persisting.
    const script = browser_tools.reverseSubstituteEnvVars(arena, args.script) catch
        return sendErrorContent(server, id, "out of memory");

    writeScript(args.path, script) catch |err| {
        const msg = std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ args.path, @errorName(err) }) catch
            return sendErrorContent(server, id, "could not write script file");
        return sendErrorContent(server, id, msg);
    };

    const where = browser_tools.absolutePath(arena, args.path);
    const lines = std.mem.count(u8, script, "\n") + 1;
    const msg = std.fmt.allocPrint(arena, "saved {d} line(s) to {s}", .{ lines, where }) catch
        return sendErrorContent(server, id, "out of memory");

    try sendToolResultText(server, id, msg, false);
}

/// The session tools need a transport that routes by session id (HTTP's
/// `Mcp-Session-Id`). Over stdio they are all unsupported, kept uniform so
/// clients see one consistent rule.
fn requireMultiSession(server: *Server, id: std.json.Value) !bool {
    if (server.multi_session) return true;
    try sendToolResultText(server, id, "multiple sessions require the HTTP transport (start with --port)", true);
    return false;
}

fn handleSessionNew(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (!try requireMultiSession(server, id)) return;
    const Args = struct { name: ?[]const u8 = null };
    const args = browser_tools.parseArgsOrDefault(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { name?: string }");
    };

    const requested: ?[]const u8 = if (args.name) |n| (if (n.len > 0) n else null) else null;
    const sid = requested orelse (server.nextSessionId(arena) catch
        return sendErrorContent(server, id, "out of memory"));

    _ = server.createSession(sid) catch |err|
        return sendErrorContent(server, id, @errorName(err));

    return sendToolResultFmt(server, arena, id, "session {s}", .{sid});
}

fn handleSessionList(server: *Server, arena: std.mem.Allocator, id: std.json.Value) !void {
    if (!try requireMultiSession(server, id)) return;
    const Entry = struct { id: []const u8, url: ?[]const u8 };
    var list: std.ArrayList(Entry) = .empty;

    var it = server.sessions.iterator();
    while (it.next()) |kv| {
        const url: ?[]const u8 = if (kv.value_ptr.*.session.currentFrame()) |frame| frame.url else null;
        list.append(arena, .{ .id = kv.key_ptr.*, .url = url }) catch
            return sendErrorContent(server, id, "out of memory");
    }

    const json = std.json.Stringify.valueAlloc(arena, list.items, .{ .emit_null_optional_fields = false }) catch
        return sendErrorContent(server, id, "out of memory");
    try sendToolResultText(server, id, json, false);
}

fn handleSessionClose(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (!try requireMultiSession(server, id)) return;
    const Args = struct { id: []const u8 };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { id: string }");
    };

    if (std.mem.eql(u8, args.id, Server.default_session_id)) {
        return sendErrorContent(server, id, "the default session cannot be closed");
    }
    // Closing the session serving this very call would tear down the isolate
    // mid-dispatch; require the client to be elsewhere first.
    if (server.sessions.get(args.id) == server.active_session) {
        return sendErrorContent(server, id, "cannot close the session you are attached to");
    }
    if (!server.closeSession(args.id)) {
        return sendErrorContent(server, id, "no such session");
    }

    return sendToolResultFmt(server, arena, id, "closed session {s}", .{args.id});
}

fn writeScript(path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{ .truncate = true });
    defer file.close(lp.io);
    try file.writeStreamingAll(lp.io, content);
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writeStreamingAll(lp.io, "\n");
}

fn sendToolResultText(server: *Server, id: std.json.Value, msg: []const u8, is_error: bool) !void {
    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.sendResult(id, protocol.CallToolResult([]const protocol.TextContent([]const u8)){ .content = &content, .isError = is_error });
}

fn sendErrorContent(server: *Server, id: std.json.Value, msg: []const u8) !void {
    return sendToolResultText(server, id, msg, true);
}

fn sendToolResultFmt(server: *Server, arena: std.mem.Allocator, id: std.json.Value, comptime fmt: []const u8, args: anytype) !void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch
        return sendErrorContent(server, id, "out of memory");
    return sendToolResultText(server, id, msg, false);
}

const router = @import("router.zig");
const testing = @import("../testing.zig");

test "MCP - tools/list carries titles and annotations" {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, all_tools, .{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const Expect = struct { name: []const u8, title: []const u8, read_only: bool, destructive: bool };
    const expected = [_]Expect{
        .{ .name = "getUrl", .title = "Show the current page URL", .read_only = true, .destructive = false },
        .{ .name = "markdown", .title = "Render the page or a subtree as markdown", .read_only = false, .destructive = false },
        .{ .name = "click", .title = "Click an element", .read_only = false, .destructive = true },
        .{ .name = "save", .title = "Save the session as an agent script", .read_only = false, .destructive = true },
        .{ .name = "session_list", .title = "List browser sessions", .read_only = true, .destructive = false },
    };

    var found: usize = 0;
    for (parsed.value.array.items) |tool| {
        const name = tool.object.get("name").?.string;
        for (expected) |e| {
            if (!std.mem.eql(u8, name, e.name)) continue;
            found += 1;
            try testing.expectEqual(e.title, tool.object.get("title").?.string);
            const a = tool.object.get("annotations").?.object;
            try testing.expectEqual(e.read_only, a.get("readOnlyHint").?.bool);
            try testing.expectEqual(e.destructive, a.get("destructiveHint").?.bool);
        }
    }
    try testing.expectEqual(expected.len, found);
}

test "MCP - evaluate error reporting" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    // Call evaluate with a script that throws an error
    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": {
        \\      "script": "throw new Error('test error')"
        \\    }
        \\  }
        \\}
    ;

    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .isError = true,
        .content = &.{.{ .type = "text" }},
    } }, out.written());
}

test "MCP - evaluate: top-level return runs in an async wrapper" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "const x = 41; return x + 1;" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "42" }},
    } }, out.written());
}

test "MCP - evaluate: top-level await runs in an async wrapper" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "const v = await Promise.resolve(41); return v + 1;" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "42" }},
    } }, out.written());
}

test "MCP - evaluate: let declaration does not leak across calls" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "let leaky = 1; leaky" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, first);

    out.clearRetainingCapacity();
    const second =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "let leaky = 2; leaky" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);

    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "2" }},
    } }, out.written());
}

test "MCP - evaluate: bare expression still returns its value" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "1 + 1" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "2" }},
    } }, out.written());
}

test "MCP - evaluate: object return serializes as JSON" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "return { n: 42, items: [1, 2] };" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "{\"n\":42,\"items\":[1,2]}" }},
    } }, out.written());
}

test "MCP - click on a target=_blank link follows the new window" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_target_blank.html", &out.writer);
    defer server.deinit();

    const click =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "click",
        \\    "arguments": { "selector": "#nt" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, click);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Opened a new window; tools now act on it. Page url: http://localhost:9582/src/browser/tests/mcp_actions.html") != null);

    out.clearRetainingCapacity();
    const get_url =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": { "name": "getUrl", "arguments": {} }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, get_url);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "http://localhost:9582/src/browser/tests/mcp_actions.html" }},
    } }, out.written());

    // navigation from inside the followed popup
    out.clearRetainingCapacity();
    const navigate =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 3,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "location.href = 'mcp_target_blank.html'" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, navigate);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":false") != null);

    out.clearRetainingCapacity();
    try router.handleMessage(server, testing.arena_allocator, get_url);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "http://localhost:9582/src/browser/tests/mcp_target_blank.html" }},
    } }, out.written());
}

test "MCP - submitting a target=_blank form follows the new window" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_target_blank.html", &out.writer);
    defer server.deinit();

    const click =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "click",
        \\    "arguments": { "selector": "#fs" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, click);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Opened a new window; tools now act on it. Page url: http://localhost:9582/src/browser/tests/mcp_actions.html?q=1") != null);
}

test "MCP - evaluate: localStorage persists across navigations and is origin-scoped" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    // 1. Set a value in localStorage on localhost
    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "localStorage.setItem('foo', 'bar'); localStorage.getItem('foo')" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, first);
    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "bar" }},
    } }, out.written());

    // 2. Navigate to another origin (127.0.0.1)
    out.clearRetainingCapacity();
    const navigate_other =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "goto",
        \\    "arguments": { "url": "http://127.0.0.1:9582/src/browser/tests/mcp_actions.html" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, navigate_other);

    // 3. Get the value on 127.0.0.1, verify it is null (isolated origin storage)
    out.clearRetainingCapacity();
    const second =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 3,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "localStorage.getItem('foo')" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);
    try testing.expectJson(.{ .id = 3, .result = .{
        .content = &.{.{ .type = "text", .text = "null" }},
    } }, out.written());

    // 4. Navigate back to localhost
    out.clearRetainingCapacity();
    const navigate_back =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 4,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "goto",
        \\    "arguments": { "url": "http://localhost:9582/src/browser/tests/mcp_actions.html" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, navigate_back);

    // 5. Get the value on localhost, verify it is still 'bar'
    out.clearRetainingCapacity();
    const third =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 5,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "localStorage.getItem('foo')" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, third);
    try testing.expectJson(.{ .id = 5, .result = .{
        .content = &.{.{ .type = "text", .text = "bar" }},
    } }, out.written());
}

test "MCP - evaluate: save= value is readable via lp.<name> in next evaluate" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const save_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "JSON.stringify('hello')", "save": "greeting" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, save_msg);

    out.clearRetainingCapacity();
    const read_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.greeting" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "hello" }},
    } }, out.written());
}

test "MCP - evaluate: save= a bare string round-trips without JSON.stringify" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const save_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "return document.title || 'untitled';", "save": "title" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, save_msg);

    out.clearRetainingCapacity();
    const read_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.title" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "untitled" }},
    } }, out.written());
}

test "MCP - evaluate: lp.* mutations auto-sync between evaluates" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.counter = 7; lp.counter" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, first);

    out.clearRetainingCapacity();
    const second =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.counter + 1" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "8" }},
    } }, out.written());
}

test "MCP - evaluate: lp.* survives navigation" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const set_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.token = 'abc'" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, set_msg);

    out.clearRetainingCapacity();
    const nav_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "goto",
        \\    "arguments": { "url": "http://127.0.0.1:9582/src/browser/tests/mcp_actions.html" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, nav_msg);

    out.clearRetainingCapacity();
    const read_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 3,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.token" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 3, .result = .{
        .content = &.{.{ .type = "text", .text = "abc" }},
    } }, out.written());
}

test "MCP - evaluate: delete lp.<key> removes from bridge store" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const set_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.tmp = 1" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, set_msg);

    out.clearRetainingCapacity();
    const del_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "delete lp.tmp; 0" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, del_msg);

    out.clearRetainingCapacity();
    const check_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 3,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "typeof lp.tmp" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, check_msg);
    try testing.expectJson(.{ .id = 3, .result = .{
        .content = &.{.{ .type = "text", .text = "undefined" }},
    } }, out.written());
}

test "MCP - extract: save= exposes the result as lp.<name>" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const extract_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "extract",
        \\    "arguments": {
        \\      "schema": "{\"btn\":\"#btn\"}",
        \\      "save": "page"
        \\    }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, extract_msg);

    out.clearRetainingCapacity();
    const read_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.page.btn" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "Click Me" }},
    } }, out.written());
}

test "MCP - evaluate: Promise.resolve return value is awaited" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "Promise.resolve(7)" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "7" }},
    } }, out.written());
}

test "MCP - evaluate: async IIFE resolves to returned value" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "(async () => { const xs = [1,2,3]; let s = 0; for (const x of xs) s += await Promise.resolve(x); return s; })()" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "6" }},
    } }, out.written());
}

test "MCP - evaluate: rejected Promise surfaces as is_error" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "(async () => { throw new Error('nope'); })()" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "nope") != null);
}

test "MCP - evaluate: async IIFE without explicit return resolves to empty text" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "(async () => { lp.touched = true; })()" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "" }},
    } }, out.written());
}

test "MCP - evaluate: lp.* mutations inside async IIFE survive to the next evaluate" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "(async () => { lp.total = 0; for (const n of [10, 20, 30]) lp.total += await Promise.resolve(n); })()" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, first);

    out.clearRetainingCapacity();
    const second =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": { "script": "lp.total" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "60" }},
    } }, out.written());
}

test "MCP - save rejects unsafe path" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save","arguments":{"path":"../escape.js","script":"goto(\"x\");"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "must be relative") != null);
}

test "MCP - save writes the script to disk" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const path = "mcp-save-test-script.js";
    std.Io.Dir.cwd().deleteFile(lp.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(lp.io, path) catch {};

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save","arguments":{"path":"mcp-save-test-script.js","script":"const page = new Page();\nawait page.goto(\"https://example.com\");"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "saved 2 line") != null);

    const written = try std.Io.Dir.cwd().readFileAlloc(lp.io, path, testing.arena_allocator, .limited(4096));
    try std.testing.expectEqualStrings("const page = new Page();\nawait page.goto(\"https://example.com\");\n", written);
}

test "MCP - tree rejects stale backendNodeId instead of dumping whole document" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tree","arguments":{"backendNodeId":999999}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "NodeNotFound") != null);
}

test "MCP - tree treats zero-filled backendNodeId as omitted" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tree","arguments":{"backendNodeId":0,"maxDepth":3}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "NodeNotFound") == null);
    try testing.expect(std.mem.indexOf(u8, written, "\"isError\":true") == null);
}

test "MCP - stale backendNodeId surfaces recovery guidance" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tree","arguments":{"backendNodeId":999999}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "NodeNotFound") != null);
    try testing.expect(std.mem.indexOf(u8, written, "omit backendNodeId") != null);
}

test "MCP - PascalCase argument keys from LLMs are normalized to canonical" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fill","arguments":{"Selector":"#inp","Value":"hello"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "\"isError\":true") == null);
    try testing.expect(std.mem.indexOf(u8, written, "InvalidParams") == null);
}

test "MCP - Actions: click, fill, scroll, hover, press, selectOption, setChecked" {
    const aa = testing.arena_allocator;

    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();
    // Poking the page directly (node registration, JS) needs its isolate
    // entered, as a tool dispatch would.
    server.active_session.enterIsolate();
    defer server.active_session.exitIsolate();

    const frame = server.active_session.session.currentFrame().?;

    {
        const btn = frame.document.getElementById("btn", frame).?.asNode();
        const btn_id = (try server.active_session.registry.register(btn)).id;
        var btn_id_buf: [12]u8 = undefined;
        const btn_id_str = std.fmt.bufPrint(&btn_id_buf, "{d}", .{btn_id}) catch unreachable;
        const click_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":", btn_id_str, "}}}" });
        try router.handleMessage(server, aa, click_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Clicked element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Page url: http://localhost:9582/src/browser/tests/mcp_actions.html") != null);
        out.clearRetainingCapacity();
    }

    {
        const inp = frame.document.getElementById("inp", frame).?.asNode();
        const inp_id = (try server.active_session.registry.register(inp)).id;
        var inp_id_buf: [12]u8 = undefined;
        const inp_id_str = std.fmt.bufPrint(&inp_id_buf, "{d}", .{inp_id}) catch unreachable;
        const fill_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", inp_id_str, ",\"value\":\"hello\"}}}" });
        try router.handleMessage(server, aa, fill_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"hello\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        const sel = frame.document.getElementById("sel", frame).?.asNode();
        const sel_id = (try server.active_session.registry.register(sel)).id;
        var sel_id_buf: [12]u8 = undefined;
        const sel_id_str = std.fmt.bufPrint(&sel_id_buf, "{d}", .{sel_id}) catch unreachable;
        const fill_sel_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", sel_id_str, ",\"value\":\"opt2\"}}}" });
        try router.handleMessage(server, aa, fill_sel_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"opt2\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        const scrollbox = frame.document.getElementById("scrollbox", frame).?.asNode();
        const scrollbox_id = (try server.active_session.registry.register(scrollbox)).id;
        var scroll_id_buf: [12]u8 = undefined;
        const scroll_id_str = std.fmt.bufPrint(&scroll_id_buf, "{d}", .{scrollbox_id}) catch unreachable;
        const scroll_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"scroll\",\"arguments\":{\"backendNodeId\":", scroll_id_str, ",\"y\":50}}}" });
        try router.handleMessage(server, aa, scroll_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Scrolled to x: 0, y: 50") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("hoverTarget", frame).?.asNode();
        const el_id = (try server.active_session.registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"hover\",\"arguments\":{\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("keyTarget", frame).?.asNode();
        const el_id = (try server.active_session.registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"press\",\"arguments\":{\"key\":\"Enter\",\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Pressed key") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("sel2", frame).?.asNode();
        const el_id = (try server.active_session.registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"selectOption\",\"arguments\":{\"backendNodeId\":", id_str, ",\"value\":\"b\"}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("chk", frame).?.asNode();
        const el_id = (try server.active_session.registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("rad", frame).?.asNode();
        const el_id = (try server.active_session.registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.exec(
        \\ window.clicked === true && window.inputVal === 'hello' &&
        \\ window.changed === true && window.selChanged === 'opt2' &&
        \\ window.scrolled === true &&
        \\ window.hovered === true &&
        \\ window.keyPressed === 'Enter' && window.keyReleased === 'Enter' &&
        \\ window.sel2Changed === 'b' &&
        \\ window.chkClicked === true && window.chkChanged === true &&
        \\ window.radClicked === true && window.radChanged === true
    , null);

    try testing.expect(result.isTrue());
}

// Regression for the segfault Karl hit on PR #2520: clicking a link via
// `backendNodeId` queued a navigation, `finalizeAction` swapped pages but
// left the registry intact, and a second click on the same id dereferenced
// a freed DOMNode.
test "MCP - click that navigates clears node registry" {
    const aa = testing.arena_allocator;

    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_nav.html", &out.writer);
    defer server.deinit();
    // Poking the page directly (node registration, JS) needs its isolate
    // entered, as a tool dispatch would.
    server.active_session.enterIsolate();
    defer server.active_session.exitIsolate();

    const before_frame = server.active_session.session.currentFrame().?;
    const link = before_frame.document.getElementById("navlink", before_frame).?.asNode();
    const link_id = (try server.active_session.registry.register(link)).id;
    try testing.expect(server.active_session.registry.lookup_by_id.contains(link_id));

    var id_buf: [12]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{link_id}) catch unreachable;
    const click_msg = try std.mem.concat(aa, u8, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":",
        id_str,
        "}}}",
    });
    try router.handleMessage(server, aa, click_msg);

    try testing.expect(server.active_session.session.currentFrame().? != before_frame);
    try testing.expect(!server.active_session.registry.lookup_by_id.contains(link_id));
}

test "MCP - Actions by selector: hover, selectOption, setChecked" {
    const aa = testing.arena_allocator;

    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();
    // Poking the page directly (node registration, JS) needs its isolate
    // entered, as a tool dispatch would.
    server.active_session.enterIsolate();
    defer server.active_session.exitIsolate();

    // Single-page test: reach straight into the live page.
    const page = server.active_session.session.pages.items[0];

    {
        const msg =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hover","arguments":{"selector":"#hoverTarget"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #hoverTarget") != null);
        out.clearRetainingCapacity();
    }

    {
        const msg =
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"selectOption","arguments":{"selector":"#sel2","value":"c"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #sel2") != null);
        out.clearRetainingCapacity();
    }

    {
        const msg =
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"setChecked","arguments":{"selector":"#chk","checked":true}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #chk") != null);
        out.clearRetainingCapacity();
    }

    {
        const msg =
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"setChecked","arguments":{"selector":"#rad","checked":true}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #rad") != null);
        out.clearRetainingCapacity();
    }

    var ls: js.Local.Scope = undefined;
    page.frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.exec(
        \\ window.hovered === true &&
        \\ window.sel2Changed === 'c' &&
        \\ window.chkClicked === true && window.chkChanged === true &&
        \\ window.radClicked === true && window.radChanged === true
    , null);

    try testing.expect(result.isTrue());
}

test "MCP - findElement" {
    const aa = testing.arena_allocator;

    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    {
        const msg =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"button"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        const msg =
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"findElement","arguments":{"name":"click"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        const msg =
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"slider"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "[]") != null);
        out.clearRetainingCapacity();
    }

    {
        const msg =
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"findElement","arguments":{}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "error") != null);
        out.clearRetainingCapacity();
    }
}

test "MCP - waitForSelector: existing element" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector on an element that already exists returns immediately
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#existing","timeout":2000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{ .content = &.{.{ .type = "text" }} } }, out.written());
}

test "MCP - waitForSelector: delayed element" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector on an element added after 200ms via setTimeout
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#delayed","timeout":5000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{ .content = &.{.{ .type = "text" }} } }, out.written());
}

test "MCP - waitForSelector: timeout" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // Missing element after the timeout surfaces as NodeNotFound, matching
    // the error /hover, /click, etc. produce when their selector misses.
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#nonexistent","timeout":100}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{
        .id = 1,
        .@"error" = .{ .message = browser_tools.errorMessage(error.NodeNotFound) },
    }, out.written());
}

test "MCP - markdown: full page, selector scope, maxBytes truncation" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const full =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"markdown"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, full);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Hover Me") != null);

    out.clearRetainingCapacity();
    const scoped =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"markdown","arguments":{"selector":"#hoverTarget"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, scoped);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Hover Me") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") == null);

    out.clearRetainingCapacity();
    const capped =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"markdown","arguments":{"maxBytes":4}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, capped);
    try testing.expect(std.mem.indexOf(u8, out.written(), "[truncated]") != null);
}

test "MCP - html: full document, selector subtree, backendNodeId subtree" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_press_form.html", &out.writer);
    defer server.deinit();

    // No args → full document (doctype + form + input).
    const full =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"html"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, full);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<form id=\\\"f\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<input id=\\\"q\\\"") != null);

    // selector → just that element's outerHTML, no doctype.
    out.clearRetainingCapacity();
    const sel =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"html","arguments":{"selector":"#q"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, sel);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<!DOCTYPE html>") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<input id=\\\"q\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<form") == null);
}

test "MCP - html: maxBytes truncation and strip" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/dump.html", &out.writer);
    defer server.deinit();

    const full =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"html"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, full);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<script>") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "[truncated]") == null);

    out.clearRetainingCapacity();
    const stripped =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"html","arguments":{"strip":{"js":true,"css":true}}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, stripped);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<style>") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<h1>Title</h1>") != null);

    out.clearRetainingCapacity();
    const capped =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"html","arguments":{"maxBytes":20}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, capped);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<h1>") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "[truncated]") != null);
}

test "MCP - screenshot: inline image, file, unsafe path" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const inline_call =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, inline_call);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"type\":\"image\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"mimeType\":\"image/png\"") != null);
    // base64 of the PNG signature
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"iVBORw0KGgo") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":false") != null);
    // Inline images are narrowed to the model-facing limit.
    try testing.expect(std.mem.indexOf(u8, out.written(), "PNG, 1280x") != null);

    const path = "mcp-screenshot-test.png";
    std.Io.Dir.cwd().deleteFile(lp.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(lp.io, path) catch {};

    out.clearRetainingCapacity();
    const to_file = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{\"path\":\"" ++ path ++ "\",\"selector\":\"#hoverTarget\"}}}";
    try router.handleMessage(server, testing.arena_allocator, to_file);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Saved 1920x") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"type\":\"image\"") == null);
    const png = try std.Io.Dir.cwd().readFileAlloc(lp.io, path, testing.arena_allocator, .limited(1024 * 1024));
    try testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));

    out.clearRetainingCapacity();
    const unsafe =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{"path":"../escape.png"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, unsafe);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);
}

test "MCP - links: dedup, hidden, text fallback, limit" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_links.html", &out.writer);
    defer server.deinit();

    const all =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"links"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, all);
    try testing.expectEqual(2, std.mem.count(u8, out.written(), "href"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "/second") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Third") != null);

    out.clearRetainingCapacity();
    const limited =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"links","arguments":{"limit":1}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, limited);
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "href"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "/first") != null);
}

test "MCP - waitForScript: truthy returns, falsy times out" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const ok =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForScript","arguments":{"script":"document.readyState === 'complete'","timeout":2000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, ok);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Script returned truthy") != null);

    out.clearRetainingCapacity();
    const timeout =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"waitForScript","arguments":{"script":"false","timeout":50}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, timeout);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Timeout") != null);
}

test "MCP - press Enter on form input triggers submit (lowercase alias)" {
    const aa = testing.arena_allocator;
    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_press_form.html", &out.writer);
    defer server.deinit();

    // Fill the input then press "enter" (lowercase alias) on it. The form's
    // submit handler sets window.submitted and snapshots the input value.
    const fill = try aa.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"selector\":\"#q\",\"value\":\"hello\"}}}");
    try router.handleMessage(server, aa, fill);
    out.clearRetainingCapacity();

    const press_msg = try aa.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"press\",\"arguments\":{\"selector\":\"#q\",\"key\":\"enter\"}}}");
    try router.handleMessage(server, aa, press_msg);
    out.clearRetainingCapacity();

    const evaluate_msg = try aa.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"evaluate\",\"arguments\":{\"script\":\"window.submitted === true && window.submittedValue === 'hello'\"}}}");
    try router.handleMessage(server, aa, evaluate_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "true") != null);
}

test "MCP - getCookies: defaults to current page, url filter, all flag" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_press_form.htm", &out.writer);
    defer server.deinit();

    try server.active_session.session.cookie_jar.populateFromResponse("http://localhost:9582", "session=abc; Path=/");
    try server.active_session.session.cookie_jar.populateFromResponse("http://other.test/", "tracking=xyz; Path=/");

    const default_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"getCookies"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, default_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "session=abc") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "tracking=xyz") == null);

    out.clearRetainingCapacity();
    const url_msg =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"getCookies","arguments":{"url":"http://other.test/"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, url_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "tracking=xyz") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "session=abc") == null);

    out.clearRetainingCapacity();
    const all_msg =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"getCookies","arguments":{"all":true}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, all_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "session=abc") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "tracking=xyz") != null);

    out.clearRetainingCapacity();
    const empty_msg =
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"getCookies","arguments":{"url":"http://nope.test/"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, empty_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "No cookies for http://nope.test/") != null);
}

test "MCP - getCookies without a loaded page refuses instead of dumping the jar" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    var server = try Server.init(testing.allocator, testing.test_app, &out.writer);
    defer server.deinit();

    try server.active_session.session.cookie_jar.populateFromResponse("http://example.com/", "session=abc; Path=/");

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"getCookies"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "session=abc") == null);
    try testing.expect(std.mem.indexOf(u8, written, "No current page") != null);
}

test "MCP - waitForState with bad state surfaces rich error" {
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForState","arguments":{"state":"x"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "invalid state 'x'") != null);
    try testing.expect(std.mem.indexOf(u8, written, "load") != null);
    try testing.expect(std.mem.indexOf(u8, written, "isError\":true") != null);
}

test "MCP - sessions: new, list, attach isolation, close" {
    const aa = testing.arena_allocator;
    var out: std.Io.Writer.Allocating = .init(aa);
    var server = try Server.init(testing.allocator, testing.test_app, &out.writer);
    defer server.deinit();
    server.multi_session = true;

    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_new","arguments":{"name":"a"}}}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "session a") != null);
    try testing.expect(server.sessions.contains("a"));

    out.clearRetainingCapacity();
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_list"}}
    );
    // The listing is JSON nested in the tool-result text, so its quotes are
    // escaped (\"default\").
    try testing.expect(std.mem.indexOf(u8, out.written(), "\\\"default\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\\\"a\\\"") != null);

    // Routing a request to "a" (as the Mcp-Session-Id header does) and loading
    // a page there leaves the default untouched, proving the two are isolated.
    _ = try server.useSession("a");
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"goto","arguments":{"url":"about:blank"}}}
    );
    try testing.expect(server.sessions.get("a").?.session.currentFrame() != null);
    try testing.expect(server.defaultSession().session.currentFrame() == null);

    // Route back to the default before closing "a" (the active session can't be closed).
    _ = try server.useSession(null);

    out.clearRetainingCapacity();
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"session_close","arguments":{"id":"default"}}}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "cannot be closed") != null);

    out.clearRetainingCapacity();
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"session_close","arguments":{"id":"a"}}}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "closed session a") != null);
    try testing.expect(!server.sessions.contains("a"));
}

fn testLoadPage(url: [:0]const u8, writer: *std.Io.Writer) !*Server {
    var server = try Server.init(testing.allocator, testing.test_app, writer);
    errdefer server.deinit();

    const session = server.active_session;
    session.enterIsolate();
    defer session.exitIsolate();

    const page = try session.session.createPage();
    try page.navigate(url, .{});

    var runner = session.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    return server;
}

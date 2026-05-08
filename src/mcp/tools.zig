const std = @import("std");

const lp = @import("lightpanda");
const js = lp.js;
const browser_tools = lp.tools;
const script = lp.script;

const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const Command = @import("../agent/Command.zig");
const Recorder = @import("../agent/Recorder.zig");

/// Convert browser tool_defs to MCP protocol.Tool format (comptime).
const browser_tool_list = blk: {
    var tools: [browser_tools.tool_defs.len]protocol.Tool = undefined;
    for (browser_tools.tool_defs, 0..) |td, i| {
        tools[i] = .{
            .name = td.name,
            .description = td.description,
            .inputSchema = td.input_schema,
        };
    }
    break :blk tools;
};

const record_start_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Relative path (no '..' segments) where PandaScript commands will be appended. The file is created if missing. Only one recording can be active at a time." }
    \\  },
    \\  "required": ["path"]
    \\}
);

const record_stop_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {}
    \\}
);

const record_comment_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "text": { "type": "string", "description": "Comment text. Written as `# <text>` to the active recording. Errors if no recording is active." }
    \\  },
    \\  "required": ["text"]
    \\}
);

const script_step_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "line": { "type": "string", "description": "A single PandaScript command (e.g. `GOTO https://x`, `CLICK '#btn'`, `TYPE '#email' 'a@b.c'`). Comments (`# …`) and blank lines are accepted as no-ops. LLM-driven keywords (LOGIN, ACCEPT_COOKIES, natural language) are rejected — the calling agent owns those." }
    \\  },
    \\  "required": ["line"]
    \\}
);

const script_heal_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Relative path of the .lp script to rewrite (no '..' segments). A `<path>.bak` of the original is written before any in-place edit." },
    \\    "replacements": {
    \\      "type": "array",
    \\      "description": "List of in-place line splices applied atomically.",
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "original_line": { "type": "string", "description": "Verbatim line to replace, exactly as it appears in the script (without trailing newline)." },
    \\          "replacement_lines": { "type": "array", "items": { "type": "string" }, "description": "New lines (without trailing newlines) to splice in. The first replacement is prefixed with `# [Auto-healed] Original: <original_line>` automatically." }
    \\        },
    \\        "required": ["original_line", "replacement_lines"]
    \\      }
    \\    }
    \\  },
    \\  "required": ["path", "replacements"]
    \\}
);

const extra_tools = [_]protocol.Tool{
    .{
        .name = "record_start",
        .description = "Start recording state-mutating browser tool calls into a PandaScript file. Subsequent calls to `goto`, `click`, `fill`, `scroll`, `hover`, `selectOption`, `setChecked`, `waitForSelector`, and `eval` get appended as PandaScript lines. Query-only tools (tree, markdown, links, findElement, …) are not recorded.",
        .inputSchema = record_start_schema,
    },
    .{
        .name = "record_stop",
        .description = "Stop the active recording and return the path and number of lines written. Errors if no recording is active.",
        .inputSchema = record_stop_schema,
    },
    .{
        .name = "record_comment",
        .description = "Append a `# <text>` comment line to the active recording. Useful as a breadcrumb above LLM-driven steps.",
        .inputSchema = record_comment_schema,
    },
    .{
        .name = "script_step",
        .description = "Parse and execute one PandaScript line on the current browser session. Returns success or a structured failure descriptor (failed line, page URL, error reason) so the calling agent can synthesize a heal step. Comments and blank lines are accepted as no-ops.",
        .inputSchema = script_step_schema,
    },
    .{
        .name = "script_heal",
        .description = "Atomically rewrite a .lp script with in-place line replacements. A `.bak` of the original is written first. Designed for the script_step → fail → script_heal roundtrip where the calling agent owns the LLM that synthesizes replacements.",
        .inputSchema = script_heal_schema,
    },
};

pub fn handleList(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    const id = req.id orelse return;
    const all = arena.alloc(protocol.Tool, browser_tool_list.len + extra_tools.len) catch return;
    @memcpy(all[0..browser_tool_list.len], &browser_tool_list);
    @memcpy(all[browser_tool_list.len..], &extra_tools);
    try server.transport.sendResult(id, .{ .tools = all });
}

pub fn handleCall(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    const id = req.id orelse return;
    const params = req.params orelse return server.transport.sendError(id, .InvalidParams, "Missing params");

    const call_params = std.json.parseFromValueLeaky(protocol.CallParams, arena, params, .{ .ignore_unknown_fields = true }) catch {
        return server.transport.sendError(id, .InvalidParams, "Invalid params");
    };

    // Hand-written tools: dispatch first so they don't collide with the
    // generated browser tools.
    if (std.mem.eql(u8, call_params.name, "record_start")) return handleRecordStart(server, arena, id, call_params.arguments);
    if (std.mem.eql(u8, call_params.name, "record_stop")) return handleRecordStop(server, arena, id);
    if (std.mem.eql(u8, call_params.name, "record_comment")) return handleRecordComment(server, arena, id, call_params.arguments);
    if (std.mem.eql(u8, call_params.name, "script_step")) return handleScriptStep(server, arena, id, call_params.arguments);
    if (std.mem.eql(u8, call_params.name, "script_heal")) return handleScriptHeal(server, arena, id, call_params.arguments);

    return dispatchBrowserTool(server, arena, id, call_params.name, call_params.arguments);
}

/// Browser-tool dispatch shared by direct MCP calls and `script_step`.
/// On success, if a recorder is active and the call maps cleanly to a
/// PandaScript Command, the call is appended to the recording.
fn dispatchBrowserTool(
    server: *Server,
    arena: std.mem.Allocator,
    id: std.json.Value,
    name: []const u8,
    arguments: ?std.json.Value,
) !void {
    const action = std.meta.stringToEnum(browser_tools.Action, name) orelse {
        return server.transport.sendError(id, .MethodNotFound, "Tool not found");
    };

    // JS errors are returned as isError tool results, not protocol errors
    if (action == .eval) {
        const result = browser_tools.callEval(arena, server.session, &server.node_registry, arguments);
        if (!result.is_error) recordIfActive(server, name, arguments);
        const content = [_]protocol.TextContent([]const u8){.{ .text = result.text }};
        return server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = result.is_error });
    }

    const result = browser_tools.call(arena, server.session, &server.node_registry, name, arguments) catch |err| {
        const code: protocol.ErrorCode = switch (err) {
            error.FrameNotLoaded => .FrameNotLoaded,
            error.NodeNotFound, error.InvalidParams => .InvalidParams,
            error.NavigationFailed, error.InternalError, error.OutOfMemory => .InternalError,
        };
        return server.transport.sendError(id, code, @errorName(err));
    };

    recordIfActive(server, name, arguments);

    const content = [_]protocol.TextContent([]const u8){.{ .text = result }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

/// If a recorder is active and the (name, args) pair maps to a PandaScript
/// Command, append it to the recording. Tools without a Command mapping
/// (tree, markdown, findElement, etc.) are silently skipped.
fn recordIfActive(server: *Server, name: []const u8, arguments: ?std.json.Value) void {
    if (server.recorder == null) return;
    const args_value = arguments orelse return;
    const cmd = Command.fromToolCallValue(name, args_value) orelse return;
    server.recorder.?.record(cmd);
    server.record_lines += 1;
}

fn handleRecordStart(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (server.recorder != null) {
        return sendErrorContent(server, id, "a recording is already active; call record_stop first");
    }
    const args_value = arguments orelse return server.transport.sendError(id, .InvalidParams, "missing arguments");
    const Args = struct { path: []const u8 };
    const args = std.json.parseFromValueLeaky(Args, arena, args_value, .{ .ignore_unknown_fields = true }) catch {
        return server.transport.sendError(id, .InvalidParams, "expected { path: string }");
    };

    if (!script.isPathSafe(args.path)) {
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
    }

    const path_owned = server.allocator.dupe(u8, args.path) catch return sendErrorContent(server, id, "out of memory");
    errdefer server.allocator.free(path_owned);

    const msg = std.fmt.allocPrint(arena, "recording started: {s}", .{path_owned}) catch {
        server.allocator.free(path_owned);
        return sendErrorContent(server, id, "out of memory");
    };

    server.recorder = Recorder.init(server.allocator, path_owned);
    server.record_path = path_owned;
    server.record_lines = 0;

    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleRecordStop(server: *Server, arena: std.mem.Allocator, id: std.json.Value) !void {
    if (server.recorder == null) {
        return sendErrorContent(server, id, "no recording is active");
    }
    const path = server.record_path.?;
    const lines = server.record_lines;

    // Build the response before nulling state so an allocPrint failure doesn't
    // strand `path` (record_path = null would hide it from Server.deinit).
    const msg = std.fmt.allocPrint(arena, "recording stopped: {s} ({d} line(s) written)", .{ path, lines }) catch
        return sendErrorContent(server, id, "out of memory");

    var r = server.recorder.?;
    r.deinit();
    server.recorder = null;
    server.record_path = null;
    server.record_lines = 0;
    server.allocator.free(path);

    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleRecordComment(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (server.recorder == null) {
        return sendErrorContent(server, id, "no recording is active");
    }
    const args_value = arguments orelse return server.transport.sendError(id, .InvalidParams, "missing arguments");
    const Args = struct { text: []const u8 };
    const args = std.json.parseFromValueLeaky(Args, arena, args_value, .{ .ignore_unknown_fields = true }) catch {
        return server.transport.sendError(id, .InvalidParams, "expected { text: string }");
    };

    server.recorder.?.recordComment(args.text);
    server.record_lines += 1;

    const content = [_]protocol.TextContent([]const u8){.{ .text = "ok" }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleScriptStep(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args_value = arguments orelse return server.transport.sendError(id, .InvalidParams, "missing arguments");
    const Args = struct { line: []const u8 };
    const args = std.json.parseFromValueLeaky(Args, arena, args_value, .{ .ignore_unknown_fields = true }) catch {
        return server.transport.sendError(id, .InvalidParams, "expected { line: string }");
    };

    const cmd = Command.parse(args.line);

    switch (cmd) {
        .comment => {
            const content = [_]protocol.TextContent([]const u8){.{ .text = "comment" }};
            return server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
        },
        .login, .accept_cookies, .natural_language => {
            return sendErrorContent(server, id, "LOGIN / ACCEPT_COOKIES / natural-language steps require an LLM and are not handled by lightpanda mcp; the calling agent owns those");
        },
        .extract => |sel| {
            const eval_script = std.fmt.allocPrint(
                arena,
                "JSON.stringify(Array.from(document.querySelectorAll({s})).map(el => el.textContent.trim()))",
                .{Command.stringifyJson(arena, sel)},
            ) catch return sendErrorContent(server, id, "out of memory building extract script");
            const result = browser_tools.evalScript(arena, server.session, &server.node_registry, eval_script);
            const content = [_]protocol.TextContent([]const u8){.{ .text = result.text }};
            return server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = result.is_error });
        },
        else => {},
    }

    // Map the Command to its underlying browser tool and dispatch through
    // the same path as a direct MCP call. Recording is intentionally NOT
    // applied to script_step lines: replay shouldn't double-record.
    const tc = Command.toToolCall(arena, cmd, Command.noSubstitute) orelse {
        return sendErrorContent(server, id, "command has no browser-tool mapping");
    };

    const tc_args: ?std.json.Value = if (tc.args_json.len == 0)
        null
    else
        std.json.parseFromSliceLeaky(std.json.Value, arena, tc.args_json, .{}) catch {
            return sendErrorContent(server, id, "internal: failed to reparse tool arguments");
        };

    const action = std.meta.stringToEnum(browser_tools.Action, tc.name) orelse {
        return sendErrorContent(server, id, "internal: unknown action from Command.toToolCall");
    };

    if (action == .eval) {
        const result = browser_tools.callEval(arena, server.session, &server.node_registry, tc_args);
        const content = [_]protocol.TextContent([]const u8){.{ .text = result.text }};
        return server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = result.is_error });
    }

    const result = browser_tools.call(arena, server.session, &server.node_registry, tc.name, tc_args) catch |err| {
        const url = currentUrl(server) catch "";
        const msg = std.fmt.allocPrint(arena, "{s} failed at line `{s}` (url: {s}): {s}", .{ tc.name, args.line, url, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    // Post-execution verification for TYPE / CHECK / SELECT: confirm the
    // DOM actually reflects the intent. Failure here drives the heal
    // roundtrip the same way an exec failure does.
    const verification = server.verifier.verify(arena, cmd);
    if (verification.result == .failed) {
        const url = currentUrl(server) catch "";
        const reason = verification.reason orelse "verification failed";
        const msg = std.fmt.allocPrint(arena, "{s} executed at line `{s}` but verification failed (url: {s}): {s}", .{ tc.name, args.line, url, reason }) catch reason;
        return sendErrorContent(server, id, msg);
    }

    const content = [_]protocol.TextContent([]const u8){.{ .text = result }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleScriptHeal(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args_value = arguments orelse return server.transport.sendError(id, .InvalidParams, "missing arguments");

    const ReplacementSpec = struct {
        original_line: []const u8,
        replacement_lines: []const []const u8,
    };
    const Args = struct {
        path: []const u8,
        replacements: []const ReplacementSpec,
    };
    const args = std.json.parseFromValueLeaky(Args, arena, args_value, .{ .ignore_unknown_fields = true }) catch {
        return server.transport.sendError(id, .InvalidParams, "expected { path: string, replacements: [{ original_line, replacement_lines }] }");
    };

    if (!script.isPathSafe(args.path)) {
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
    }

    const content = std.fs.cwd().readFileAlloc(arena, args.path, 10 * 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(arena, "failed to read {s}: {s}", .{ args.path, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    var splices = arena.alloc(script.Replacement, args.replacements.len) catch return sendErrorContent(server, id, "out of memory");

    for (args.replacements, 0..) |spec, i| {
        const span = findLineSpan(content, spec.original_line) catch |err| {
            const reason: []const u8 = switch (err) {
                error.NotFound => "original_line not found verbatim",
                error.Ambiguous => "original_line matches more than one line; make it unique to disambiguate",
            };
            const msg = std.fmt.allocPrint(arena, "{s}: `{s}`", .{ reason, spec.original_line }) catch reason;
            return sendErrorContent(server, id, msg);
        };

        splices[i] = script.formatHealReplacementLines(arena, span, spec.original_line, spec.replacement_lines) catch |err|
            return sendErrorContent(server, id, @errorName(err));
    }

    script.writeAtomic(arena, std.fs.cwd(), args.path, content, splices) catch |err| {
        const msg = std.fmt.allocPrint(arena, "failed to write {s}: {s} (script left unchanged)", .{ args.path, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    const msg = std.fmt.allocPrint(arena, "healed {d} line(s) in {s}; backup at {s}.bak", .{ args.replacements.len, args.path, args.path }) catch "ok";
    const out_content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &out_content });
}

/// Find a line in `content` that exactly equals `line` (after trimming the
/// trailing newline). Returns the slice covering the line plus its
/// terminating `\n` if present, ready for `script.applyReplacements`.
/// Errors if the line is missing or matches more than once — a duplicate
/// match would silently rewrite the wrong line and break
/// applyReplacements' non-overlapping invariant.
fn findLineSpan(content: []const u8, line: []const u8) error{ NotFound, Ambiguous }![]const u8 {
    var pos: usize = 0;
    var found: ?[]const u8 = null;
    while (pos <= content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const this_line = content[pos..nl];
        if (std.mem.eql(u8, this_line, line)) {
            if (found != null) return error.Ambiguous;
            const end = if (nl < content.len) nl + 1 else nl;
            found = content[pos..end];
        }
        if (nl == content.len) break;
        pos = nl + 1;
    }
    return found orelse error.NotFound;
}

fn currentUrl(server: *Server) ![]const u8 {
    const frame = server.session.currentFrame() orelse return "(no page loaded)";
    return frame.url;
}

fn sendErrorContent(server: *Server, id: std.json.Value, msg: []const u8) !void {
    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.transport.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = true });
}

const router = @import("router.zig");
const testing = @import("../testing.zig");

test "MCP - eval error reporting" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    // Call eval with a script that throws an error
    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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

test "MCP - findLineSpan: exact match returns line + trailing newline" {
    const content = "GOTO https://x\nCLICK 'old'\nWAIT '.thanks'\n";
    const span = try findLineSpan(content, "CLICK 'old'");
    try std.testing.expectEqualStrings("CLICK 'old'\n", span);
}

test "MCP - findLineSpan: no match returns NotFound" {
    const content = "GOTO https://x\nCLICK 'a'\n";
    try std.testing.expectError(error.NotFound, findLineSpan(content, "CLICK 'b'"));
}

test "MCP - findLineSpan: last line without trailing newline" {
    const content = "GOTO https://x\nCLICK 'last'";
    const span = try findLineSpan(content, "CLICK 'last'");
    try std.testing.expectEqualStrings("CLICK 'last'", span);
}

test "MCP - findLineSpan: duplicate line returns Ambiguous" {
    const content = "CLICK 'go'\nWAIT '.x'\nCLICK 'go'\n";
    try std.testing.expectError(error.Ambiguous, findLineSpan(content, "CLICK 'go'"));
}

test "MCP - record_start rejects unsafe path" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_start","arguments":{"path":"../escape.lp"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "must be relative") != null);
}

test "MCP - record_stop without active recording errors" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_stop","arguments":{}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "no recording is active") != null);
}

test "MCP - script_step rejects natural-language input" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_step","arguments":{"line":"please summarize this page"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "require an LLM") != null);
}

test "MCP - script_step runs TYPE and verifier passes" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    // TYPE on the input that exists on the test page; verifier checks
    // the field's `value` property after execution.
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_step","arguments":{"line":"TYPE '#inp' 'hello world'"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "verification failed") == null);
}

test "MCP - script_step accepts comment line" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_step","arguments":{"line":"# fetch the homepage"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") == null);
}

test "MCP - Actions: click, fill, scroll, hover, press, selectOption, setChecked" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const frame = server.session.currentFrame().?;

    {
        // Test Click
        const btn = frame.document.getElementById("btn", frame).?.asNode();
        const btn_id = (try server.node_registry.register(btn)).id;
        var btn_id_buf: [12]u8 = undefined;
        const btn_id_str = std.fmt.bufPrint(&btn_id_buf, "{d}", .{btn_id}) catch unreachable;
        const click_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":", btn_id_str, "}}}" });
        try router.handleMessage(server, aa, click_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Clicked element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Page url: http://localhost:9582/src/browser/tests/mcp_actions.html") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Fill Input
        const inp = frame.document.getElementById("inp", frame).?.asNode();
        const inp_id = (try server.node_registry.register(inp)).id;
        var inp_id_buf: [12]u8 = undefined;
        const inp_id_str = std.fmt.bufPrint(&inp_id_buf, "{d}", .{inp_id}) catch unreachable;
        const fill_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", inp_id_str, ",\"value\":\"hello\"}}}" });
        try router.handleMessage(server, aa, fill_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"hello\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Fill Select
        const sel = frame.document.getElementById("sel", frame).?.asNode();
        const sel_id = (try server.node_registry.register(sel)).id;
        var sel_id_buf: [12]u8 = undefined;
        const sel_id_str = std.fmt.bufPrint(&sel_id_buf, "{d}", .{sel_id}) catch unreachable;
        const fill_sel_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", sel_id_str, ",\"value\":\"opt2\"}}}" });
        try router.handleMessage(server, aa, fill_sel_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"opt2\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Scroll
        const scrollbox = frame.document.getElementById("scrollbox", frame).?.asNode();
        const scrollbox_id = (try server.node_registry.register(scrollbox)).id;
        var scroll_id_buf: [12]u8 = undefined;
        const scroll_id_str = std.fmt.bufPrint(&scroll_id_buf, "{d}", .{scrollbox_id}) catch unreachable;
        const scroll_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"scroll\",\"arguments\":{\"backendNodeId\":", scroll_id_str, ",\"y\":50}}}" });
        try router.handleMessage(server, aa, scroll_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Scrolled to x: 0, y: 50") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Hover
        const el = frame.document.getElementById("hoverTarget", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"hover\",\"arguments\":{\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Press
        const el = frame.document.getElementById("keyTarget", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"press\",\"arguments\":{\"key\":\"Enter\",\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Pressed key") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SelectOption
        const el = frame.document.getElementById("sel2", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"selectOption\",\"arguments\":{\"backendNodeId\":", id_str, ",\"value\":\"b\"}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SetChecked (checkbox)
        const el = frame.document.getElementById("chk", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SetChecked (radio)
        const el = frame.document.getElementById("rad", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    // Evaluate JS assertions for all actions
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

test "MCP - Actions by selector: hover, selectOption, setChecked" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const page = server.session.currentPage().?;

    {
        // Hover by selector
        const msg =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hover","arguments":{"selector":"#hoverTarget"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #hoverTarget") != null);
        out.clearRetainingCapacity();
    }

    {
        // SelectOption by selector
        const msg =
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"selectOption","arguments":{"selector":"#sel2","value":"c"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #sel2") != null);
        out.clearRetainingCapacity();
    }

    {
        // SetChecked checkbox by selector
        const msg =
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"setChecked","arguments":{"selector":"#chk","checked":true}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #chk") != null);
        out.clearRetainingCapacity();
    }

    {
        // SetChecked radio by selector
        const msg =
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"setChecked","arguments":{"selector":"#rad","checked":true}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "selector: #rad") != null);
        out.clearRetainingCapacity();
    }

    // Verify the underlying actions actually fired their handlers
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
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    {
        // Find by role
        const msg =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"button"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        // Find by name (case-insensitive substring)
        const msg =
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"findElement","arguments":{"name":"click"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        // Find with no matches
        const msg =
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"slider"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "[]") != null);
        out.clearRetainingCapacity();
    }

    {
        // Error: no params provided
        const msg =
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"findElement","arguments":{}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "error") != null);
        out.clearRetainingCapacity();
    }
}

test "MCP - waitForSelector: existing element" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector with a short timeout on a non-existent element should error
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#nonexistent","timeout":100}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{
        .id = 1,
        .@"error" = struct {}{},
    }, out.written());
}

fn testLoadPage(url: [:0]const u8, writer: *std.Io.Writer) !*Server {
    var server = try Server.init(testing.allocator, testing.test_app, writer);
    errdefer server.deinit();

    const frame = try server.session.createPage();
    try frame.navigate(url, .{});

    var runner = try server.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });
    return server;
}

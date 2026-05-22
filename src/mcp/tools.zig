const std = @import("std");

const lp = @import("lightpanda");
const js = lp.js;
const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const script = lp.script;
const Command = lp.script.Command;
const Recorder = lp.script.Recorder;

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
    \\    "line": { "type": "string", "description": "A single PandaScript slash command (e.g. `/goto 'https://x'`, `/click selector='#btn'`, `/fill selector='#email' value='a@b.c'`). Comments (`# …`) and blank lines are accepted as no-ops. LLM-driven slash commands (`/login`, `/acceptCookies`) and anything that isn't a slash command are rejected — the calling agent owns those." }
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

const extra_tools = [_]McpTool{
    .{
        .name = "record_start",
        .description = "Start recording state-mutating browser tool calls into a PandaScript file. Subsequent calls to `goto`, `click`, `fill`, `scroll`, `hover`, `selectOption`, `setChecked`, `waitForSelector`, `eval`, and `extract` get appended as PandaScript lines. Query-only tools (tree, markdown, links, findElement, …) are not recorded.",
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

const all_tools = browser_tool_list ++ extra_tools;

/// Tools that bypass the browser-tool dispatch and have their own handlers.
const ExtraTool = enum {
    record_start,
    record_stop,
    record_comment,
    script_step,
    script_heal,
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
            .record_start => handleRecordStart(server, arena, id, call_params.arguments),
            .record_stop => handleRecordStop(server, arena, id),
            .record_comment => handleRecordComment(server, arena, id, call_params.arguments),
            .script_step => handleScriptStep(server, arena, id, call_params.arguments),
            .script_heal => handleScriptHeal(server, arena, id, call_params.arguments),
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

    const result = browser_tools.call(arena, server.session, &server.node_registry, name, arguments) catch |err| {
        // eval/extract surface failures in-band so the LLM can self-correct;
        // other tools' operational failures are protocol-level.
        if (surfacesErrorInBand(tool)) {
            return sendToolResultText(server, id, @errorName(err), true);
        }
        const code: protocol.ErrorCode = switch (err) {
            error.FrameNotLoaded => .FrameNotLoaded,
            error.NodeNotFound, error.InvalidParams => .InvalidParams,
            error.NavigationFailed, error.Cancelled, error.Timeout, error.InternalError, error.OutOfMemory => .InternalError,
        };
        return server.sendError(id, code, @errorName(err));
    };

    if (!result.is_error) recordIfActive(server, tool, arguments);

    try sendToolResultText(server, id, result.text, result.is_error);
}

fn surfacesErrorInBand(tool: BrowserTool) bool {
    return tool == .eval or tool == .extract;
}

fn recordIfActive(server: *Server, tool: BrowserTool, arguments: ?std.json.Value) void {
    if (server.recorder == null) return;
    const cmd = Command.fromToolCall(tool, arguments);
    // `record` no-ops on non-recorded tools — see `Command.isRecorded`.
    server.recorder.?.record(cmd);
}

fn handleRecordStart(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (server.recorder != null) {
        return sendErrorContent(server, id, "a recording is already active; call record_stop first");
    }
    const Args = struct { path: []const u8 };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { path: string }");
    };

    if (!script.isPathSafe(args.path)) {
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
    }

    var recorder = Recorder.init(server.allocator, std.fs.cwd(), args.path) catch |err| {
        const msg = std.fmt.allocPrint(arena, "could not open recording file: {s}", .{@errorName(err)}) catch
            return sendErrorContent(server, id, "could not open recording file");
        return sendErrorContent(server, id, msg);
    };
    const msg = std.fmt.allocPrint(arena, "recording started: {s}", .{recorder.path}) catch {
        recorder.deinit();
        return sendErrorContent(server, id, "out of memory");
    };
    server.recorder = recorder;

    try sendToolResultText(server, id, msg, false);
}

fn handleRecordStop(server: *Server, arena: std.mem.Allocator, id: std.json.Value) !void {
    if (server.recorder == null) {
        return sendErrorContent(server, id, "no recording is active");
    }
    var r = server.recorder.?;
    // Build the response before deinit so we can quote the path/lines.
    const msg = std.fmt.allocPrint(arena, "recording stopped: {s} ({d} line(s) written)", .{ r.path, r.lines }) catch
        return sendErrorContent(server, id, "out of memory");

    r.deinit();
    server.recorder = null;

    try sendToolResultText(server, id, msg, false);
}

fn handleRecordComment(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (server.recorder == null) {
        return sendErrorContent(server, id, "no recording is active");
    }
    const Args = struct { text: []const u8 };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { text: string }");
    };

    server.recorder.?.recordComment(args.text);

    try sendToolResultText(server, id, "ok", false);
}

fn handleScriptStep(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Args = struct { line: []const u8 };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { line: string }");
    };

    const cmd = Command.parse(arena, args.line) catch |err| {
        const msg = std.fmt.allocPrint(arena, "could not parse step `{s}`: {s}", .{ args.line, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    if (cmd.needsLlm()) {
        return sendErrorContent(server, id, "/login and /acceptCookies require an LLM and are not handled by lightpanda mcp; the calling agent owns those");
    }

    if (cmd == .comment) {
        return sendToolResultText(server, id, "comment", false);
    }

    const tc = cmd.tool_call;
    const result = browser_tools.call(arena, server.session, &server.node_registry, tc.name(), tc.args) catch |err| {
        if (surfacesErrorInBand(tc.tool)) {
            return sendErrorContent(server, id, @errorName(err));
        }
        const url = browser_tools.currentUrlOrPlaceholder(server.session);
        const msg = std.fmt.allocPrint(arena, "{s} failed at line `{s}` (url: {s}): {s}", .{ tc.name(), args.line, url, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    // Post-exec verification drives the heal roundtrip on fill/setChecked/selectOption;
    // for eval/extract `verify` is a no-op (.inconclusive).
    switch (server.verifier.verify(arena, cmd)) {
        .failed => |reason| {
            const url = browser_tools.currentUrlOrPlaceholder(server.session);
            const msg = std.fmt.allocPrint(arena, "{s} executed at line `{s}` but verification failed (url: {s}): {s}", .{ tc.name(), args.line, url, reason }) catch reason;
            return sendErrorContent(server, id, msg);
        },
        .passed, .inconclusive => {},
    }

    try sendToolResultText(server, id, result.text, result.is_error);
}

fn handleScriptHeal(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ReplacementSpec = struct {
        original_line: []const u8,
        replacement_lines: []const []const u8,
    };
    const Args = struct {
        path: []const u8,
        replacements: []const ReplacementSpec,
    };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { path: string, replacements: [{ original_line, replacement_lines }] }");
    };

    if (!script.isPathSafe(args.path)) {
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
    }

    const content = std.fs.cwd().readFileAlloc(arena, args.path, 10 * 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(arena, "failed to read {s}: {s}", .{ args.path, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    if (args.replacements.len == 0) {
        const msg = std.fmt.allocPrint(arena, "healed 0 line(s) in {s}", .{args.path}) catch "ok";
        try sendToolResultText(server, id, msg, false);
        return;
    }

    var splices = arena.alloc(script.Replacement, args.replacements.len) catch return sendErrorContent(server, id, "out of memory");

    const index = indexLines(arena, content) catch return sendErrorContent(server, id, "out of memory");

    for (args.replacements, 0..) |spec, i| {
        const entry = index.get(spec.original_line) orelse {
            const msg = std.fmt.allocPrint(arena, "original_line not found verbatim: `{s}`", .{spec.original_line}) catch "original_line not found verbatim";
            return sendErrorContent(server, id, msg);
        };
        if (entry.dup) {
            const msg = std.fmt.allocPrint(arena, "original_line matches more than one line; make it unique to disambiguate: `{s}`", .{spec.original_line}) catch "original_line matches more than one line; make it unique to disambiguate";
            return sendErrorContent(server, id, msg);
        }

        splices[i] = script.formatHealReplacement(arena, entry.span, spec.original_line, .{ .lines = spec.replacement_lines }) catch |err|
            return sendErrorContent(server, id, @errorName(err));
    }

    // applyReplacements requires spans in file order and non-overlapping.
    // The LLM may emit replacements unordered, and two specs can resolve to
    // the same line. Sort by span offset, then reject duplicates so a single
    // line can't be healed twice.
    std.mem.sort(script.Replacement, splices, {}, struct {
        fn lt(_: void, a: script.Replacement, b: script.Replacement) bool {
            return @intFromPtr(a.original_span.ptr) < @intFromPtr(b.original_span.ptr);
        }
    }.lt);
    for (splices[1..], splices[0 .. splices.len - 1]) |cur, prev| {
        if (@intFromPtr(cur.original_span.ptr) == @intFromPtr(prev.original_span.ptr)) {
            return sendErrorContent(server, id, "two replacements target the same original_line; merge them into one entry");
        }
    }

    script.writeAtomic(arena, std.fs.cwd(), args.path, content, splices) catch |err| {
        const msg = std.fmt.allocPrint(arena, "failed to write {s}: {s} (script left unchanged)", .{ args.path, @errorName(err) }) catch @errorName(err);
        return sendErrorContent(server, id, msg);
    };

    const msg = std.fmt.allocPrint(arena, "healed {d} line(s) in {s}; backup at {s}.bak", .{ args.replacements.len, args.path, args.path }) catch "ok";
    try sendToolResultText(server, id, msg, false);
}

const LineEntry = struct { span: []const u8, dup: bool };

/// Walk `content` once and map each unique line to the slice covering that
/// line plus its terminating `\n`. Duplicate lines are flagged via `dup` so
/// the caller can reject ambiguous matches — `applyReplacements`'
/// non-overlapping invariant would break if two specs resolved to the same
/// span.
fn indexLines(arena: std.mem.Allocator, content: []const u8) !std.StringHashMapUnmanaged(LineEntry) {
    var index: std.StringHashMapUnmanaged(LineEntry) = .empty;
    var pos: usize = 0;
    while (pos <= content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const this_line = content[pos..nl];
        const end = if (nl < content.len) nl + 1 else nl;
        const gop = try index.getOrPut(arena, this_line);
        if (gop.found_existing) {
            gop.value_ptr.dup = true;
        } else {
            gop.value_ptr.* = .{ .span = content[pos..end], .dup = false };
        }
        if (nl == content.len) break;
        pos = nl + 1;
    }
    return index;
}

fn sendToolResultText(server: *Server, id: std.json.Value, msg: []const u8, is_error: bool) !void {
    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = is_error });
}

fn sendErrorContent(server: *Server, id: std.json.Value, msg: []const u8) !void {
    return sendToolResultText(server, id, msg, true);
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

test "MCP - indexLines: exact match returns line + trailing newline" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/goto 'https://x'\n/click selector='old'\n/waitForSelector '.thanks'\n";
    const index = try indexLines(arena.allocator(), content);
    const entry = index.get("/click selector='old'").?;
    try std.testing.expect(!entry.dup);
    try std.testing.expectEqualStrings("/click selector='old'\n", entry.span);
}

test "MCP - indexLines: missing line absent from index" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/goto 'https://x'\n/click selector='a'\n";
    const index = try indexLines(arena.allocator(), content);
    try std.testing.expect(index.get("/click selector='b'") == null);
}

test "MCP - indexLines: last line without trailing newline" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/goto 'https://x'\n/click selector='last'";
    const index = try indexLines(arena.allocator(), content);
    try std.testing.expectEqualStrings("/click selector='last'", index.get("/click selector='last'").?.span);
}

test "MCP - indexLines: duplicate line flagged dup" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/click selector='go'\n/waitForSelector '.x'\n/click selector='go'\n";
    const index = try indexLines(arena.allocator(), content);
    try std.testing.expect(index.get("/click selector='go'").?.dup);
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

test "MCP - script_step rejects /login (LLM-required)" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_step","arguments":{"line":"/login"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "require an LLM") != null);
}

test "MCP - script_step rejects bare prose" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_step","arguments":{"line":"please summarize this page"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "could not parse step") != null);
}

test "MCP - script_step runs /fill and verifier passes" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    // /fill on the input that exists on the test page; verifier checks
    // the field's `value` property after execution.
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_step","arguments":{"line":"/fill selector='#inp' value='hello world'"}}}
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

// Regression for the segfault Karl hit on PR #2520: clicking a link via
// `backendNodeId` queued a navigation, `finalizeAction` swapped pages but
// left the registry intact, and a second click on the same id dereferenced
// a freed DOMNode.
test "MCP - click that navigates clears node registry" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_nav.html", &out.writer);
    defer server.deinit();

    const before_frame = server.session.currentFrame().?;
    const link = before_frame.document.getElementById("navlink", before_frame).?.asNode();
    const link_id = (try server.node_registry.register(link)).id;
    try testing.expect(server.node_registry.lookup_by_id.contains(link_id));

    var id_buf: [12]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{link_id}) catch unreachable;
    const click_msg = try std.mem.concat(aa, u8, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":",
        id_str,
        "}}}",
    });
    try router.handleMessage(server, aa, click_msg);

    try testing.expect(server.session.currentFrame().? != before_frame);
    try testing.expect(!server.node_registry.lookup_by_id.contains(link_id));
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

    // Missing element after the timeout surfaces as NodeNotFound, matching
    // the error /hover, /click, etc. produce when their selector misses.
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#nonexistent","timeout":100}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{
        .id = 1,
        .@"error" = .{ .message = "NodeNotFound" },
    }, out.written());
}

test "MCP - html dumps doctype + document element" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_press_form.html", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"html"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<form id=\\\"f\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<input id=\\\"q\\\"") != null);
}

test "MCP - waitForScript: truthy returns, falsy times out" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    const aa = testing.arena_allocator;
    var out: std.io.Writer.Allocating = .init(aa);
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

    const eval_msg = try aa.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"eval\",\"arguments\":{\"script\":\"window.submitted === true && window.submittedValue === 'hello'\"}}}");
    try router.handleMessage(server, aa, eval_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "true") != null);
}

test "MCP - getCookies: defaults to current page, url filter, all flag" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://example.com/", &out.writer);
    defer server.deinit();

    try server.session.cookie_jar.populateFromResponse("http://example.com/", "session=abc; Path=/");
    try server.session.cookie_jar.populateFromResponse("http://other.test/", "tracking=xyz; Path=/");

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

test "MCP - goto with bad waitUntil surfaces rich error" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"about:blank","waitUntil":"x"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "invalid waitUntil 'x'") != null);
    try testing.expect(std.mem.indexOf(u8, written, "load") != null);
    try testing.expect(std.mem.indexOf(u8, written, "isError\":true") != null);
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

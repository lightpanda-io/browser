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
        .name = "recordStart",
        .description = "Start recording state-mutating browser tool calls into a PandaScript file. Subsequent calls to `goto`, `click`, `fill`, `scroll`, `hover`, `selectOption`, `setChecked`, `waitForSelector`, `eval`, and `extract` get appended as PandaScript lines. Query-only tools (tree, markdown, links, findElement, …) are not recorded.",
        .inputSchema = record_start_schema,
    },
    .{
        .name = "recordStop",
        .description = "Stop the active recording and return the path and number of lines written. Errors if no recording is active.",
        .inputSchema = record_stop_schema,
    },
    .{
        .name = "recordComment",
        .description = "Append a `# <text>` comment line to the active recording. Useful as a breadcrumb above LLM-driven steps.",
        .inputSchema = record_comment_schema,
    },
    .{
        .name = "scriptStep",
        .description = "Parse and execute one PandaScript line on the current browser session. Returns success or a structured failure descriptor (failed line, page URL, error reason) so the calling agent can synthesize a heal step. Comments and blank lines are accepted as no-ops.",
        .inputSchema = script_step_schema,
    },
    .{
        .name = "scriptHeal",
        .description = "Atomically rewrite a .lp script with in-place line replacements. A `.bak` of the original is written first. Designed for the scriptStep → fail → scriptHeal roundtrip where the calling agent owns the LLM that synthesizes replacements.",
        .inputSchema = script_heal_schema,
    },
};

const all_tools = browser_tool_list ++ extra_tools;

/// Tools that bypass the browser-tool dispatch and have their own handlers.
const ExtraTool = enum {
    recordStart,
    recordStop,
    recordComment,
    scriptStep,
    scriptHeal,
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
            .recordStart => handleRecordStart(server, arena, id, call_params.arguments),
            .recordStop => handleRecordStop(server, arena, id),
            .recordComment => handleRecordComment(server, arena, id, call_params.arguments),
            .scriptStep => handleScriptStep(server, arena, id, call_params.arguments),
            .scriptHeal => handleScriptHeal(server, arena, id, call_params.arguments),
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
            error.Cancelled => .Cancelled,
            error.Timeout => .Timeout,
            error.NavigationFailed, error.InternalError, error.OutOfMemory => .InternalError,
        };
        return server.sendError(id, code, @errorName(err));
    };

    if (!result.is_error) recordIfActive(arena, server, tool, arguments);

    try sendToolResultText(server, id, result.text, result.is_error);
}

fn surfacesErrorInBand(tool: BrowserTool) bool {
    return tool == .eval or tool == .extract;
}

fn recordIfActive(arena: std.mem.Allocator, server: *Server, tool: BrowserTool, arguments: ?std.json.Value) void {
    if (server.recorder == null) return;
    const normalized = browser_tools.normalizeArgKeys(arena, tool, arguments) catch arguments;
    const cmd = Command.fromToolCall(tool, normalized);
    // `record` no-ops on non-recorded tools — see `Command.isRecorded`.
    server.recorder.?.record(cmd);
}

fn handleRecordStart(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    if (server.recorder != null) {
        return sendErrorContent(server, id, "a recording is already active; call recordStop first");
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

    var diag: lp.script.Schema.Diag = .{};
    const cmd = Command.parseDiag(arena, args.line, &diag) catch |err| {
        const msg = if (err == error.InvalidValue and diag.bad_field.len > 0)
            std.fmt.allocPrint(arena, "could not parse step `{s}`: {s}: expected {s}, got '{s}'", .{ args.line, diag.bad_field, @tagName(diag.expected_type), diag.bad_value }) catch @errorName(err)
        else
            std.fmt.allocPrint(arena, "could not parse step `{s}`: {s}", .{ args.line, @errorName(err) }) catch @errorName(err);
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
        const msg = std.fmt.allocPrint(arena, "failed to write {s}: {s} {s}", .{ args.path, @errorName(err), script.writeAtomicErrorTail(err) }) catch @errorName(err);
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
        // Strip the CR from CRLF before keying so an LLM-supplied `original_line`
        // (always plain `\n`) matches a file saved with Windows / autocrlf endings.
        // The span still covers the full `\r\n` so the splice replaces both bytes.
        const lookup_key = std.mem.trimRight(u8, content[pos..nl], "\r");
        const line_end = if (nl < content.len) nl + 1 else nl;

        // Multi-line block openers (`/eval '''`, `/extract """`, …) must
        // index the whole block as one span — keyed by the opener line —
        // so a splice doesn't orphan the body and closing fence.
        const span_end = blk: {
            const trimmed = std.mem.trim(u8, content[pos..nl], &std.ascii.whitespace);
            const split = script.Schema.parseSlashCommand(trimmed) orelse break :blk line_end;
            const s = script.Schema.findByName(split.name) orelse break :blk line_end;
            if (!s.isMultiLineCapable()) break :blk line_end;
            const qt = script.Schema.QuoteType.fromLiteral(split.rest) orelse break :blk line_end;
            break :blk findBlockClose(content, line_end, qt.toLiteral()) orelse line_end;
        };

        const gop = try index.getOrPut(arena, lookup_key);
        if (gop.found_existing) {
            gop.value_ptr.dup = true;
        } else {
            gop.value_ptr.* = .{ .span = content[pos..span_end], .dup = false };
        }

        if (span_end > line_end) {
            if (span_end >= content.len) break;
            pos = span_end;
        } else {
            if (nl == content.len) break;
            pos = nl + 1;
        }
    }
    return index;
}

/// Scan from `start` for a line whose trimmed-right (CR-stripped) content
/// equals `closer`. Returns the byte position immediately after that
/// line's terminating `\n` (or `content.len` if the closer is the tail
/// line with no trailing newline). Returns null if the closer is missing.
fn findBlockClose(content: []const u8, start: usize, closer: []const u8) ?usize {
    var pos = start;
    while (pos <= content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const scrubbed = std.mem.trimRight(u8, content[pos..nl], "\r");
        if (std.mem.eql(u8, scrubbed, closer)) {
            return if (nl < content.len) nl + 1 else nl;
        }
        if (nl == content.len) return null;
        pos = nl + 1;
    }
    return null;
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

test "MCP - eval: top-level return retried inside IIFE" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
        \\    "arguments": { "script": "const x = 41; return x + 1;" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "42" }},
    } }, out.written());
}

test "MCP - eval: let declaration does not leak across calls" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
        \\    "arguments": { "script": "let leaky = 2; leaky" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);

    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "2" }},
    } }, out.written());
}

test "MCP - eval: bare expression still returns its value" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
        \\    "arguments": { "script": "1 + 1" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "2" }},
    } }, out.written());
}

test "MCP - eval: localStorage persists across navigations and is origin-scoped" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    // 1. Set a value in localStorage on localhost
    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
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
        \\    "name": "eval",
        \\    "arguments": { "script": "localStorage.getItem('foo')" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, third);
    try testing.expectJson(.{ .id = 5, .result = .{
        .content = &.{.{ .type = "text", .text = "bar" }},
    } }, out.written());
}

test "MCP - eval: save= value is readable via lp.<name> in next eval" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const save_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
        \\    "arguments": { "script": "lp.greeting" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "hello" }},
    } }, out.written());
}

test "MCP - eval: lp.* mutations auto-sync between evals" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
        \\    "arguments": { "script": "lp.counter + 1" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "8" }},
    } }, out.written());
}

test "MCP - eval: lp.* survives navigation" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const set_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
        \\    "arguments": { "script": "lp.token" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 3, .result = .{
        .content = &.{.{ .type = "text", .text = "abc" }},
    } }, out.written());
}

test "MCP - eval: delete lp.<key> removes from bridge store" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const set_msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
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
        \\    "name": "eval",
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
        \\    "name": "eval",
        \\    "arguments": { "script": "lp.page.btn" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, read_msg);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "Click Me" }},
    } }, out.written());
}

test "MCP - eval: Promise.resolve return value is awaited" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
        \\    "arguments": { "script": "Promise.resolve(7)" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "7" }},
    } }, out.written());
}

test "MCP - eval: async IIFE resolves to returned value" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
        \\    "arguments": { "script": "(async () => { const xs = [1,2,3]; let s = 0; for (const x of xs) s += await Promise.resolve(x); return s; })()" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{ .id = 1, .result = .{
        .content = &.{.{ .type = "text", .text = "6" }},
    } }, out.written());
}

test "MCP - eval: rejected Promise surfaces as is_error" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
        \\    "arguments": { "script": "(async () => { throw new Error('nope'); })()" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "nope") != null);
}

test "MCP - eval: lp.* mutations inside async IIFE survive to the next eval" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const first =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "eval",
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
        \\    "name": "eval",
        \\    "arguments": { "script": "lp.total" }
        \\  }
        \\}
    ;
    try router.handleMessage(server, testing.arena_allocator, second);
    try testing.expectJson(.{ .id = 2, .result = .{
        .content = &.{.{ .type = "text", .text = "60" }},
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

test "MCP - indexLines: multi-line block span covers opener through closer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/goto 'https://x'\n/eval '''\nconst x = 1;\nreturn x;\n'''\n/tree\n";
    const index = try indexLines(arena.allocator(), content);

    const block = index.get("/eval '''").?;
    try std.testing.expect(!block.dup);
    try std.testing.expectEqualStrings("/eval '''\nconst x = 1;\nreturn x;\n'''\n", block.span);

    // Body lines stay out of the index — splicing them individually would
    // corrupt the block.
    try std.testing.expect(index.get("const x = 1;") == null);
    try std.testing.expect(index.get("return x;") == null);
    try std.testing.expect(index.get("'''") == null);

    // Siblings before/after the block remain individually addressable.
    try std.testing.expectEqualStrings("/goto 'https://x'\n", index.get("/goto 'https://x'").?.span);
    try std.testing.expectEqualStrings("/tree\n", index.get("/tree").?.span);
}

test "MCP - indexLines: unterminated block falls back to single-line indexing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/eval '''\nconst x = 1;\n";
    const index = try indexLines(arena.allocator(), content);
    // No closer found → opener is indexed as a normal single line so the
    // user can still heal it (e.g. to add the missing fence).
    try std.testing.expectEqualStrings("/eval '''\n", index.get("/eval '''").?.span);
    try std.testing.expectEqualStrings("const x = 1;\n", index.get("const x = 1;").?.span);
}

test "MCP - indexLines: CRLF line endings still match plain LLM keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = "/goto 'https://x'\r\n/click selector='old'\r\n/waitForSelector '.thanks'\r\n";
    const index = try indexLines(arena.allocator(), content);
    const entry = index.get("/click selector='old'").?;
    try std.testing.expect(!entry.dup);
    try std.testing.expectEqualStrings("/click selector='old'\r\n", entry.span);
}

test "MCP - recordStart rejects unsafe path" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recordStart","arguments":{"path":"../escape.lp"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "must be relative") != null);
}

test "MCP - recordStop without active recording errors" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recordStop","arguments":{}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "no recording is active") != null);
}

test "MCP - scriptStep rejects /login (LLM-required)" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scriptStep","arguments":{"line":"/login"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "require an LLM") != null);
}

test "MCP - scriptStep rejects bare prose" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scriptStep","arguments":{"line":"please summarize this page"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "could not parse step") != null);
}

test "MCP - scriptStep runs /fill and verifier passes" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    // /fill on the input that exists on the test page; verifier checks
    // the field's `value` property after execution.
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scriptStep","arguments":{"line":"/fill selector='#inp' value='hello world'"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "verification failed") == null);
}

test "MCP - scriptStep accepts comment line" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scriptStep","arguments":{"line":"# fetch the homepage"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") == null);
}

test "MCP - tree rejects stale backendNodeId instead of dumping whole document" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tree","arguments":{"backendNodeId":999999}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "NodeNotFound") != null);
}

test "MCP - PascalCase argument keys from LLMs are normalized to canonical" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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

test "MCP - markdown: full page, selector scope, maxBytes truncation" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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

test "MCP - getCookies without a loaded page refuses instead of dumping the jar" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    var server = try Server.init(testing.allocator, testing.test_app, &out.writer);
    defer server.deinit();

    try server.session.cookie_jar.populateFromResponse("http://example.com/", "session=abc; Path=/");

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"getCookies"}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "session=abc") == null);
    try testing.expect(std.mem.indexOf(u8, written, "No current page") != null);
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

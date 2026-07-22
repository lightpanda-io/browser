const std = @import("std");

const lp = @import("lightpanda");
const js = lp.js;
const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const ScriptRuntime = lp.Runtime;
const string = @import("../string.zig");

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

const replay_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Relative path (no '..' segments) of the saved script to replay." },
    \\    "script": { "type": "string", "description": "Optional: script text to run instead of the file's contents - trial a candidate revision without writing it. `path` still names the run." }
    \\  },
    \\  "required": ["path"]
    \\}
);

const heal_commit_schema = browser_tools.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Relative path (no '..' segments) of the broken script; replaced atomically only on cure." },
    \\    "script": { "type": "string", "description": "The full revised script. Keep $LP_* placeholders; never inline a resolved secret." },
    \\    "failure": {
    \\      "type": "object",
    \\      "description": "The `failure` object from the replay report you are healing, echoed back verbatim.",
    \\      "properties": {
    \\        "kind": { "type": "string", "enum": ["threw", "empty", "dry_extracts"] },
    \\        "detail": { "type": "string" },
    \\        "dry_fields": { "type": "array", "items": { "type": "string" }, "description": "For dry_extracts: the fields that must come back with data (\"\" = a whole-array extract). Deleting an extract is not a cure." }
    \\      },
    \\      "required": ["kind"]
    \\    }
    \\  },
    \\  "required": ["path", "script", "failure"]
    \\}
);

/// Appended to the `initialize` instructions (`driver_guidance` is shared with
/// the standalone agent, which has no replay/heal tools — keep this MCP-only).
pub const script_lifecycle_note =
    \\Script lifecycle: `save` a finished session as a script, `replay` it
    \\any time for a token-free re-run, and when a replay reports it broken,
    \\heal it — diagnose against the live session, then `heal_commit` a
    \\revision (validated in a fresh session before it replaces the file).
    \\
;

const extra_tools = [_]McpTool{
    .{
        .name = "replay",
        .description = "Replay a saved Lightpanda agent script (see `save`) and return a JSON run report. `status` is \"ok\" (ran, output carries data), \"suspicious\" (ran clean but the output looks dry — judge whether that is breakage or the page genuinely has no such data right now, weighing any `// lp:baseline` comment in `source` as evidence of what the fields held at save time), or \"failed\" (the script threw). The script's `console.*` output and returned value arrive in `console` (the returned value is the final line). On suspicious/failed the report carries the script `source`, a `failure` object and `guidance` for the heal flow: diagnose against the live session, then call `heal_commit`. Pass `script` to trial a candidate revision without writing it. The replay drives this session — the current page, cookies and node ids are replaced; re-inspect (tree) before reusing node ids.",
        .inputSchema = replay_schema,
    },
    .{
        .name = "heal_commit",
        .description = "Commit a healed script: the revised `script` is validated by replaying it in a fresh session, and only a validated cure replaces the file at `path` — the original is untouched otherwise. Echo back the `failure` object from the replay report you are healing; the cure check is deterministic: `threw` needs a clean run, `empty` needs the return value to carry data, `dry_extracts` needs every listed field to come back with data (deleting the extract is not a cure). The response is a JSON heal report; on `cured: false` its `failure` says what is still wrong — diagnose further and try again. Afterwards the session is the fresh validation session at the script's end state (all prior node ids are stale).\n\n" ++ lp.heal.heal_revision_prompt ++ "\n\n" ++ browser_tools.save_synthesis_prompt ++ "\n\n" ++ browser_tools.save_script_rules,
        .inputSchema = heal_commit_schema,
    },
    .{
        .name = "save",
        .description = "Save the session as a reusable Lightpanda agent script. You hold the conversation, so synthesize the `script` yourself — `const page = new Page(); await page.goto(url);` then call the builtins you used as tools (extract, click, fill, …) as methods on `page` with the same object arguments. Keep `$LP_*` placeholders; never inline a resolved secret.\n\n" ++ browser_tools.save_synthesis_prompt ++ "\n\n" ++ browser_tools.save_script_rules,
        .inputSchema = save_schema,
    },
    .{
        .name = "session_new",
        .description = "Create a new isolated browser session (its own page, cookies and memory) and return its id. Use it to give a separate agent its own browsing context, or to obtain an id to share. Pass that id back as the `Mcp-Session-Id` header to route calls to it.",
        .inputSchema = session_new_schema,
    },
    .{
        .name = "session_list",
        .description = "List the active browser sessions with their id and current URL. The `default` session always exists.",
        .inputSchema = browser_tools.minify("{ \"type\": \"object\", \"properties\": {} }"),
    },
    .{
        .name = "session_close",
        .description = "Close a browser session, freeing its page and memory. The `default` session cannot be closed.",
        .inputSchema = session_id_schema,
    },
};

const all_tools = browser_tool_list ++ extra_tools;

/// Tools that bypass the browser-tool dispatch and have their own handlers.
const ExtraTool = enum {
    replay,
    heal_commit,
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
            .replay => handleReplay(server, arena, id, call_params.arguments),
            .heal_commit => handleHealCommit(server, arena, id, call_params.arguments),
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
    const result = browser_tools.call(arena, active.session, &active.node_registry, name, arguments) catch |err| {
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
        return server.sendError(id, code, @errorName(err));
    };

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
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
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

    // Absolute path: the cwd is the client-launched server's, not one the user picked.
    const where = std.fs.cwd().realpathAlloc(arena, args.path) catch args.path;
    const lines = std.mem.count(u8, script, "\n") + 1;
    const msg = std.fmt.allocPrint(arena, "saved {d} line(s) to {s}", .{ lines, where }) catch
        return sendErrorContent(server, id, "out of memory");

    try sendToolResultText(server, id, msg, false);
}

// Agent parity: the CLI reads scripts with the same bound.
const max_script_bytes = 10 * 1024 * 1024;

/// Bound `RunReport.source` — a script is human-scale, but a synthesized one
/// with an embedded blob shouldn't balloon the report.
const source_max_bytes = 64 * 1024;

/// Caps captured `console.*` output so a chatty script can't balloon the
/// report.
const ConsoleCollector = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayList(lp.heal.ConsoleLine) = .empty,
    bytes: usize = 0,
    truncated: bool = false,

    const max_bytes = 16 * 1024;

    fn sink(self: *ConsoleCollector) ScriptRuntime.ConsoleSink {
        return .{ .context = @ptrCast(self), .write = write };
    }

    fn write(context: *anyopaque, method: ScriptRuntime.ConsoleMethod, line: []const u8) void {
        const self: *ConsoleCollector = @ptrCast(@alignCast(context));
        if (self.bytes >= max_bytes) {
            self.truncated = true;
            return;
        }
        // Scrub any resolved LP_* secret a script may have printed.
        const scrubbed = browser_tools.reverseSubstituteEnvVars(self.arena, line) catch {
            self.truncated = true;
            return;
        };
        const capped = string.capBytes(self.arena, scrubbed, max_bytes - self.bytes);
        if (capped.ptr != scrubbed.ptr) self.truncated = true;
        // A line that passed through both unchanged still aliases the
        // runtime's per-call arena, which dies before the report is sent.
        const text = if (capped.ptr == line.ptr)
            self.arena.dupe(u8, capped) catch {
                self.truncated = true;
                return;
            }
        else
            capped;
        self.lines.append(self.arena, .{ .level = @tagName(method), .text = text }) catch {
            self.truncated = true;
            return;
        };
        self.bytes += text.len;
    }
};

fn runClassified(server: *Server, arena: std.mem.Allocator, path: []const u8, source: []const u8, collector: *ConsoleCollector) !lp.heal.Classified {
    const active = server.active_session;
    const runtime = try ScriptRuntime.init(server.allocator, server.app, active.session, &active.node_registry);
    defer runtime.deinit();
    runtime.console_sink = collector.sink();
    const result = try runtime.runSource(source, path);
    return lp.heal.classifyRun(arena, result, source);
}

fn buildRunReport(
    arena: std.mem.Allocator,
    path: []const u8,
    classified: lp.heal.Classified,
    collector: *const ConsoleCollector,
    with_guidance: bool,
) error{OutOfMemory}!lp.heal.RunReport {
    var report: lp.heal.RunReport = .{
        .status = .ok,
        .path = path,
        .console = collector.lines.items,
        .console_truncated = collector.truncated,
    };
    switch (classified) {
        .script_error => |script_error| {
            report.status = .failed;
            report.failure = try lp.heal.wireFailure(arena, script_error);
            report.source = try scrubbedSource(arena, script_error.source);
            if (with_guidance) report.guidance = lp.heal.replay_failed_guidance;
        },
        .facts => |facts| {
            report.returned = facts.returned;
            report.extracts = facts.extract_stats;
            if (lp.heal.suspicionOf(arena, facts)) |suspicion| {
                report.status = .suspicious;
                report.failure = try lp.heal.wireFailure(arena, suspicion);
                report.source = try scrubbedSource(arena, facts.source);
                if (with_guidance) report.guidance = lp.heal.replay_suspicious_guidance;
            }
        },
    }
    return report;
}

fn scrubbedSource(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const u8 {
    return string.capBytes(arena, try browser_tools.reverseSubstituteEnvVars(arena, source), source_max_bytes);
}

fn sendReport(server: *Server, arena: std.mem.Allocator, id: std.json.Value, report: anytype) !void {
    const json = std.json.Stringify.valueAlloc(arena, report, .{ .emit_null_optional_fields = false }) catch
        return sendErrorContent(server, id, "out of memory");
    try sendToolResultText(server, id, json, false);
}

fn handleReplay(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Args = struct { path: []const u8, script: ?[]const u8 = null };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { path: string, script?: string }");
    };
    if (!browser_tools.isPathSafe(args.path)) {
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
    }
    const source = args.script orelse std.fs.cwd().readFileAlloc(arena, args.path, max_script_bytes) catch |err| {
        const msg = std.fmt.allocPrint(arena, "could not read {s}: {s}", .{ args.path, @errorName(err) }) catch "could not read script";
        return sendErrorContent(server, id, msg);
    };

    var collector: ConsoleCollector = .{ .arena = arena };
    const classified = runClassified(server, arena, args.path, source, &collector) catch |err| switch (err) {
        error.OutOfMemory => return sendErrorContent(server, id, "out of memory"),
        error.RuntimeInitFailed, error.TooManyContexts => return sendErrorContent(server, id, "could not initialize the script runtime"),
    };
    // A failed script is still a successful replay: report it in-band, never
    // as a tool error — the report is the answer.
    const report = buildRunReport(arena, args.path, classified, &collector, true) catch
        return sendErrorContent(server, id, "out of memory");
    return sendReport(server, arena, id, report);
}

fn handleHealCommit(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Args = struct { path: []const u8, script: []const u8, failure: lp.heal.WireFailure };
    const args = browser_tools.parseArgs(Args, arena, arguments) catch {
        return server.sendError(id, .InvalidParams, "expected { path: string, script: string, failure: { kind, detail?, dry_fields? } }");
    };
    if (!browser_tools.isPathSafe(args.path)) {
        return sendErrorContent(server, id, "path must be relative and must not contain '..' segments");
    }
    const first = lp.heal.scriptErrorFromWire(arena, args.failure) catch
        return sendErrorContent(server, id, "out of memory");
    // The client never sees resolved secrets, but scrub as a safety net
    // before running or persisting the candidate.
    const script = browser_tools.reverseSubstituteEnvVars(arena, args.script) catch
        return sendErrorContent(server, id, "out of memory");

    // Validate in a fresh session so failure-state cookies and pages can't
    // mask a still-broken script.
    server.restartSession(server.active_session) catch |err| {
        const msg = std.fmt.allocPrint(arena, "could not start a fresh session: {s}", .{@errorName(err)}) catch "could not start a fresh session";
        return sendErrorContent(server, id, msg);
    };

    var collector: ConsoleCollector = .{ .arena = arena };
    const classified = runClassified(server, arena, args.path, script, &collector) catch |err| switch (err) {
        error.OutOfMemory => return sendErrorContent(server, id, "out of memory"),
        error.RuntimeInitFailed, error.TooManyContexts => return sendErrorContent(server, id, "could not initialize the script runtime"),
    };
    const run = buildRunReport(arena, args.path, classified, &collector, false) catch
        return sendErrorContent(server, id, "out of memory");

    var report: lp.heal.HealReport = .{ .cured = false, .committed = false, .run = run };
    switch (classified) {
        .script_error => |script_error| report.failure = script_error.detail,
        .facts => |facts| {
            const residual = lp.heal.cureFailure(arena, first, facts) catch
                return sendErrorContent(server, id, "out of memory");
            if (residual) |failure| {
                report.failure = failure;
            } else {
                report.cured = true;
                commitHealed(arena, args.path, script, facts.extract_stats, &report);
            }
        },
    }
    return sendReport(server, arena, id, report);
}

/// Write the validated revision next to `path` and atomically swap it in,
/// refreshing the `// lp:baseline` line from the validation run. Failures
/// land in the report (`cured` stays true, `committed` false).
fn commitHealed(arena: std.mem.Allocator, path: []const u8, script: []const u8, stats: []const ScriptRuntime.ExtractStat, report: *lp.heal.HealReport) void {
    const final = lp.heal.refreshedBaselineScript(arena, script, stats) orelse script;
    const tmp_path = std.fmt.allocPrint(arena, "{s}.heal.js", .{path}) catch {
        report.failure = "validated, but out of memory writing the revision";
        return;
    };
    writeScript(tmp_path, final) catch |err| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        report.failure = std.fmt.allocPrint(arena, "validated, but writing {s} failed: {s}", .{ tmp_path, @errorName(err) }) catch null;
        return;
    };
    std.fs.cwd().rename(tmp_path, path) catch |err| {
        // Deliberately keep the revision; the message points at it.
        report.failure = std.fmt.allocPrint(arena, "validated, but replacing {s} failed: {s} (revision left at {s})", .{ path, @errorName(err), tmp_path }) catch null;
        return;
    };
    report.committed = true;
}

/// The session tools require the HTTP transport's parked-isolate discipline:
/// a second session means a second V8 isolate, only safe when isolates are
/// entered around use. Over stdio (one permanently-entered isolate) they are
/// all unsupported, kept uniform so clients see one consistent rule.
fn requireMultiSession(server: *Server, id: std.json.Value) !bool {
    if (server.park_isolates) return true;
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

    var it = server.sessions.valueIterator();
    while (it.next()) |entry| {
        const url: ?[]const u8 = if (entry.*.session.currentFrame()) |frame| frame.url else null;
        list.append(arena, .{ .id = entry.*.id, .url = url }) catch
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
    if (std.mem.eql(u8, args.id, server.active_session.id)) {
        return sendErrorContent(server, id, "cannot close the session you are attached to");
    }
    if (!server.closeSession(args.id)) {
        return sendErrorContent(server, id, "no such session");
    }

    return sendToolResultFmt(server, arena, id, "closed session {s}", .{args.id});
}

fn writeScript(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writeAll("\n");
}

fn sendToolResultText(server: *Server, id: std.json.Value, msg: []const u8, is_error: bool) !void {
    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = is_error });
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

test "MCP - evaluate error reporting" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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

test "MCP - evaluate: localStorage persists across navigations and is origin-scoped" {
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save","arguments":{"path":"../escape.js","script":"goto(\"x\");"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "must be relative") != null);
}

test "MCP - save writes the script to disk" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const path = "mcp-save-test-script.js";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save","arguments":{"path":"mcp-save-test-script.js","script":"const page = new Page();\nawait page.goto(\"https://example.com\");"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "saved 2 line") != null);

    const written = try std.fs.cwd().readFileAlloc(testing.arena_allocator, path, 4096);
    try std.testing.expectEqualStrings("const page = new Page();\nawait page.goto(\"https://example.com\");\n", written);
}

fn testToolText(arena: std.mem.Allocator, response: []const u8) ![]const u8 {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trim(u8, response, " \n"), .{});
    return root.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
}

fn testCall(server: *Server, out: *std.io.Writer.Allocating, name: []const u8, arguments: anytype) ![]const u8 {
    const arena = testing.arena_allocator;
    const args_json = try std.json.Stringify.valueAlloc(arena, arguments, .{});
    const msg = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ name, args_json });
    const start = out.written().len;
    try router.handleMessage(server, arena, msg);
    return testToolText(arena, out.written()[start..]);
}

fn testCallReport(server: *Server, out: *std.io.Writer.Allocating, name: []const u8, arguments: anytype) !std.json.Value {
    const text = try testCall(server, out, name, arguments);
    return std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, text, .{});
}

const test_fixture_url = "http://localhost:9582/src/browser/tests/mcp_actions.html";

test "MCP - replay rejects unsafe path" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"replay","arguments":{"path":"../evil.js"}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "must be relative") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);
}

test "MCP - replay: inline clean run reports ok" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const report = try testCallReport(server, &out, "replay", .{ .path = "t.js", .script = "return [1];" });
    try testing.expectString("ok", report.object.get("status").?.string);
    try testing.expectString("data", report.object.get("returned").?.string);
    try testing.expectEqual(null, report.object.get("failure"));
    try testing.expectEqual(null, report.object.get("guidance"));
}

test "MCP - replay: throwing script reports failed with failure and guidance" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const report = try testCallReport(server, &out, "replay", .{ .path = "t.js", .script = "throw new Error(\"boom\");" });
    try testing.expectString("failed", report.object.get("status").?.string);
    const failure = report.object.get("failure").?.object;
    try testing.expectString("threw", failure.get("kind").?.string);
    try testing.expect(std.mem.indexOf(u8, failure.get("detail").?.string, "boom") != null);
    try testing.expectString("throw new Error(\"boom\");", report.object.get("source").?.string);
    try testing.expect(std.mem.indexOf(u8, report.object.get("guidance").?.string, "heal_commit") != null);
}

test "MCP - replay: empty return reports suspicious" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const report = try testCallReport(server, &out, "replay", .{ .path = "t.js", .script = "return [];" });
    try testing.expectString("suspicious", report.object.get("status").?.string);
    try testing.expectString("empty", report.object.get("returned").?.string);
    try testing.expectString("empty", report.object.get("failure").?.object.get("kind").?.string);
    try testing.expect(std.mem.indexOf(u8, report.object.get("guidance").?.string, "lp:baseline") != null);
}

test "MCP - replay: dry extract reports suspicious with dry_fields" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(test_fixture_url, &out.writer);
    defer server.deinit();

    const script =
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\return page.extract({ btn: ["#btn"], missing: [".no-such-thing"] });
    ;
    const report = try testCallReport(server, &out, "replay", .{ .path = "t.js", .script = script });
    try testing.expectString("suspicious", report.object.get("status").?.string);
    const failure = report.object.get("failure").?.object;
    try testing.expectString("dry_extracts", failure.get("kind").?.string);
    const dry = failure.get("dry_fields").?.array.items;
    try testing.expectEqual(1, dry.len);
    try testing.expectString("missing", dry[0].string);
    try testing.expectEqual(2, report.object.get("extracts").?.array.items.len);
}

test "MCP - replay: console lines are captured in the report" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const report = try testCallReport(server, &out, "replay", .{ .path = "t.js", .script = "console.log(\"hello\", 42);\nreturn [1];" });
    const console = report.object.get("console").?.array.items;
    try testing.expectEqual(2, console.len);
    try testing.expectString("log", console[0].object.get("level").?.string);
    try testing.expectString("hello 42", console[0].object.get("text").?.string);
    // The returned value is echoed as the final console line — how a replay
    // hands its output to the client.
    try testing.expectString("[1]", console[1].object.get("text").?.string);
    try testing.expectEqual(false, report.object.get("console_truncated").?.bool);
}

test "MCP - heal_commit: uncured candidate leaves the file untouched" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const path = "mcp-heal-uncured-test.js";
    std.fs.cwd().deleteFile(path) catch {};

    const report = try testCallReport(server, &out, "heal_commit", .{
        .path = path,
        .script = "return [];",
        .failure = .{ .kind = "empty" },
    });
    try testing.expectEqual(false, report.object.get("cured").?.bool);
    try testing.expectEqual(false, report.object.get("committed").?.bool);
    try testing.expect(std.mem.indexOf(u8, report.object.get("failure").?.string, "no data") != null);
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
}

test "MCP - heal_commit: cure commits atomically and refreshes the baseline" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    const path = "mcp-heal-cure-test.js";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "return [];\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const revised =
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\return page.extract({ btn: ["#btn"] });
    ;
    const report = try testCallReport(server, &out, "heal_commit", .{
        .path = path,
        .script = revised,
        .failure = .{ .kind = "empty" },
    });
    try testing.expectEqual(true, report.object.get("cured").?.bool);
    try testing.expectEqual(true, report.object.get("committed").?.bool);
    try testing.expectString("ok", report.object.get("run").?.object.get("status").?.string);

    const written = try std.fs.cwd().readFileAlloc(testing.arena_allocator, path, 4096);
    try testing.expect(std.mem.startsWith(u8, written, "const page = new Page();"));
    try testing.expect(std.mem.indexOf(u8, written, "// lp:baseline ") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"btn\":{\"calls\":1,\"nonempty\":1}") != null);
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path ++ ".heal.js", .{}));
}

test "MCP - script lifecycle: save, replay broken, heal_commit, replay clean" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(test_fixture_url, &out.writer);
    defer server.deinit();

    const path = "mcp-lifecycle-test.js";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    const broken =
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\return page.extract({ btn: [".no-such-btn"] });
    ;
    const saved = try testCall(server, &out, "save", .{ .path = path, .script = broken });
    try testing.expect(std.mem.indexOf(u8, saved, "saved") != null);

    const run = try testCallReport(server, &out, "replay", .{ .path = path });
    try testing.expectString("suspicious", run.object.get("status").?.string);
    const failure = run.object.get("failure").?;

    // The test plays the client model: fix the selector, echo the failure back.
    const revised =
        \\const page = new Page();
        \\await page.goto("http://localhost:9582/src/browser/tests/mcp_actions.html");
        \\return page.extract({ btn: ["#btn"] });
    ;
    const healed = try testCallReport(server, &out, "heal_commit", .{
        .path = path,
        .script = revised,
        .failure = failure,
    });
    try testing.expectEqual(true, healed.object.get("cured").?.bool);
    try testing.expectEqual(true, healed.object.get("committed").?.bool);

    const rerun = try testCallReport(server, &out, "replay", .{ .path = path });
    try testing.expectString("ok", rerun.object.get("status").?.string);
    try testing.expectString("data", rerun.object.get("returned").?.string);
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

    const frame = server.active_session.session.currentFrame().?;

    {
        const btn = frame.document.getElementById("btn", frame).?.asNode();
        const btn_id = (try server.active_session.node_registry.register(btn)).id;
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
        const inp_id = (try server.active_session.node_registry.register(inp)).id;
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
        const sel_id = (try server.active_session.node_registry.register(sel)).id;
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
        const scrollbox_id = (try server.active_session.node_registry.register(scrollbox)).id;
        var scroll_id_buf: [12]u8 = undefined;
        const scroll_id_str = std.fmt.bufPrint(&scroll_id_buf, "{d}", .{scrollbox_id}) catch unreachable;
        const scroll_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"scroll\",\"arguments\":{\"backendNodeId\":", scroll_id_str, ",\"y\":50}}}" });
        try router.handleMessage(server, aa, scroll_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Scrolled to x: 0, y: 50") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("hoverTarget", frame).?.asNode();
        const el_id = (try server.active_session.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"hover\",\"arguments\":{\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("keyTarget", frame).?.asNode();
        const el_id = (try server.active_session.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"press\",\"arguments\":{\"key\":\"Enter\",\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Pressed key") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("sel2", frame).?.asNode();
        const el_id = (try server.active_session.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"selectOption\",\"arguments\":{\"backendNodeId\":", id_str, ",\"value\":\"b\"}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("chk", frame).?.asNode();
        const el_id = (try server.active_session.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    {
        const el = frame.document.getElementById("rad", frame).?.asNode();
        const el_id = (try server.active_session.node_registry.register(el)).id;
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
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_nav.html", &out.writer);
    defer server.deinit();

    const before_frame = server.active_session.session.currentFrame().?;
    const link = before_frame.document.getElementById("navlink", before_frame).?.asNode();
    const link_id = (try server.active_session.node_registry.register(link)).id;
    try testing.expect(server.active_session.node_registry.lookup_by_id.contains(link_id));

    var id_buf: [12]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{link_id}) catch unreachable;
    const click_msg = try std.mem.concat(aa, u8, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":",
        id_str,
        "}}}",
    });
    try router.handleMessage(server, aa, click_msg);

    try testing.expect(server.active_session.session.currentFrame().? != before_frame);
    try testing.expect(!server.active_session.node_registry.lookup_by_id.contains(link_id));
}

test "MCP - Actions by selector: hover, selectOption, setChecked" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

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
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
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

    const evaluate_msg = try aa.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"evaluate\",\"arguments\":{\"script\":\"window.submitted === true && window.submittedValue === 'hello'\"}}}");
    try router.handleMessage(server, aa, evaluate_msg);
    try testing.expect(std.mem.indexOf(u8, out.written(), "true") != null);
}

test "MCP - getCookies: defaults to current page, url filter, all flag" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
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
    defer testing.reset();
    const aa = testing.arena_allocator;
    var out: std.io.Writer.Allocating = .init(aa);
    var server = try Server.init(testing.allocator, testing.test_app, &out.writer);
    defer server.deinit();
    // Session tools require the HTTP transport's parked-isolate discipline.
    server.enableIsolateParking();

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

    const page = try server.active_session.session.createPage();
    try page.navigate(url, .{});

    var runner = server.active_session.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    return server;
}

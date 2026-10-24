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
const zenai = @import("zenai");

const NodeRegistry = @import("../NodeRegistry.zig");
const TelemetryTool = @import("../telemetry/telemetry.zig").Event.Tool;

const DOMNode = @import("webapi/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");
const SelectorPath = @import("SelectorPath.zig");
const Element = @import("webapi/Element.zig");
const prompts = @import("tools/prompts.zig");
const definitions = @import("tools/definitions.zig");
const marshal = @import("tools/marshal.zig");

/// The names callers outside this file already use; `tools/marshal.zig`
/// is where they live.
pub const parseArgs = marshal.parseArgs;
pub const parseValue = marshal.parseValue;
pub const lpEnvNames = marshal.lpEnvNames;
pub const normalizeArgs = marshal.normalizeArgs;
pub const substituteEnvVars = marshal.substituteEnvVars;
pub const reverseSubstituteEnvVars = marshal.reverseSubstituteEnvVars;

pub const parseArgsOrDefault = marshal.parseArgsOrDefault;
const substituteStringArgs = marshal.substituteStringArgs;
const diagnoseArgs = marshal.diagnoseArgs;
const diagnoseMissingRequired = marshal.diagnoseMissingRequired;
const lookupLpEnv = marshal.lookupLpEnv;
pub const search = @import("tools/search.zig");

const log = lp.log;

pub const driver_guidance = prompts.driver_guidance;
pub const save_synthesis_prompt = prompts.save_synthesis_prompt;
pub const save_script_rules = prompts.save_script_rules;

/// Reject paths that an untrusted MCP client could use to escape the
/// working directory: empty paths, absolute paths, and any path with a
/// `..` segment. Operator-controlled symlinks already inside CWD are out
/// of scope — the threat we close here is "client supplies an arbitrary
/// path string".
pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

pub const unsafe_path_message = "path must be relative and must not contain '..' segments";

/// The cwd is the server's, not one the user picked, so report where a file
/// really went.
pub fn absolutePath(arena: std.mem.Allocator, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(lp.io, path, arena) catch path;
}

/// Hand-written so per-tool semantics (record/heal/locator/data) and
/// LLM-facing metadata (`definition`) live as exhaustive switches on the
/// tag — adding a new tool is a compile error until each predicate AND
/// `definition` make an explicit choice. `tool_defs` (below) materializes
/// `definition` over every tag for callers that iterate.
pub const Tool = enum {
    goto,
    search,
    markdown,
    html,
    screenshot,
    links,
    evaluate,
    extract,
    tree,
    nodeDetails,
    interactiveElements,
    structuredData,
    detectForms,
    click,
    fill,
    scroll,
    waitForSelector,
    waitForScript,
    waitForState,
    hover,
    press,
    selectOption,
    setChecked,
    findElement,
    consoleLogs,
    getUrl,
    getCookies,
    getEnv,
    classify,
    acceptCookies,
    login,

    /// Telemetry wire id: append, never renumber. 0 is reserved for a name
    /// that matched no tool.
    pub fn telemetryId(self: Tool) u8 {
        return switch (self) {
            .goto => 1,
            .search => 2,
            .markdown => 3,
            .html => 4,
            .screenshot => 5,
            .links => 6,
            .evaluate => 7,
            .extract => 8,
            .tree => 9,
            .nodeDetails => 10,
            .interactiveElements => 11,
            .structuredData => 12,
            .detectForms => 13,
            .click => 14,
            .fill => 15,
            .scroll => 16,
            .waitForSelector => 17,
            .waitForScript => 18,
            .waitForState => 19,
            .hover => 20,
            .press => 21,
            .selectOption => 22,
            .setChecked => 23,
            .findElement => 24,
            .consoleLogs => 25,
            .getUrl => 26,
            .getCookies => 27,
            .getEnv => 28,
            .classify => 29,
            .acceptCookies => 30,
            .login => 31,
        };
    }

    /// State-mutating: surfaces in JavaScript recordings. Read-only tools
    /// (queries, env probes) stay out so a replay doesn't bloat the script
    /// with noise.
    pub fn isRecorded(self: Tool) bool {
        return switch (self) {
            .goto, .screenshot, .evaluate, .extract, .click, .fill, .scroll, .waitForSelector, .waitForScript, .waitForState, .hover, .press, .selectOption, .setChecked, .classify, .acceptCookies, .login => true,
            .search, .markdown, .html, .links, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Whether the tool's script form returns a Promise and so is recorded with
    /// `await`. Only `goto` (navigation) is async; every other page method is
    /// synchronous. Exhaustive like the sibling predicates so adding an async
    /// tool is a compile error until it makes an explicit choice here.
    pub fn isAsync(self: Tool) bool {
        return switch (self) {
            .goto => true,
            .evaluate, .extract, .classify, .acceptCookies, .login, .click, .fill, .scroll, .waitForSelector, .waitForScript, .waitForState, .hover, .press, .selectOption, .setChecked, .search, .markdown, .html, .screenshot, .links, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Waits for page readiness on its own, letting the recorder downgrade a
    /// preceding `goto` to `domcontentloaded`. Exhaustive like the sibling
    /// predicates so a new wait tool makes an explicit choice here.
    pub fn waitsForReadiness(self: Tool) bool {
        return switch (self) {
            .waitForSelector, .waitForScript, .waitForState => true,
            .goto, .evaluate, .extract, .classify, .acceptCookies, .login, .click, .fill, .scroll, .hover, .press, .selectOption, .setChecked, .search, .markdown, .html, .screenshot, .links, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// A read tool that navigates when handed a `url`. The read isn't recorded,
    /// but the navigation is, so the recorder captures it as a `goto`. Excludes
    /// `evaluate` (carries its own `url`), `search` (derived engine URL), and
    /// `getCookies` (`url` filters, not navigates).
    pub fn navigatesToUrl(self: Tool) bool {
        return switch (self) {
            .markdown, .html, .screenshot, .links, .tree, .interactiveElements, .structuredData, .detectForms => true,
            .goto, .search, .evaluate, .extract, .classify, .acceptCookies, .login, .nodeDetails, .click, .fill, .scroll, .waitForSelector, .waitForScript, .waitForState, .hover, .press, .selectOption, .setChecked, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Args a replay needs even though the schema marks them optional; the
    /// recorder skips a line missing one. Exhaustive so a new tool must choose.
    pub fn replayRequires(self: Tool) []const []const u8 {
        return switch (self) {
            .click, .fill, .hover, .selectOption, .setChecked => &.{"selector"},
            .screenshot => &.{"path"},
            .goto, .search, .markdown, .html, .links, .evaluate, .extract, .classify, .acceptCookies, .login, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .scroll, .waitForSelector, .waitForScript, .waitForState, .press, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => &.{},
        };
    }

    /// Result is data the caller probably wants on stdout (extracted JSON,
    /// markdown, evaluate return value) rather than a status line on stderr.
    pub fn producesData(self: Tool) bool {
        return switch (self) {
            .search, .markdown, .html, .links, .evaluate, .extract, .classify, .acceptCookies, .login, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => true,
            .goto, .screenshot, .click, .fill, .scroll, .waitForSelector, .waitForScript, .waitForState, .hover, .press, .selectOption, .setChecked => false,
        };
    }

    /// Result text is JSON, so a script gets the parsed value, not the string.
    pub fn returnsJson(self: Tool) bool {
        return switch (self) {
            .extract, .classify, .acceptCookies, .login => true,
            .goto, .search, .markdown, .html, .links, .evaluate, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv, .screenshot, .click, .fill, .scroll, .waitForSelector, .waitForScript, .waitForState, .hover, .press, .selectOption, .setChecked => false,
        };
    }

    /// The result is a navigation outcome and nothing else, so `PageState` is
    /// a faithful machine-readable form of it. `evaluate` is excluded though
    /// it reports the same facts: there they are a suffix on the payload that
    /// is the real answer, and a client following the usual "prefer
    /// `structuredContent`" rule would keep the suffix and drop the payload.
    pub fn reportsPageState(self: Tool) bool {
        return switch (self) {
            .goto, .click, .fill, .scroll, .hover, .press, .selectOption, .setChecked => true,
            .search, .markdown, .html, .links, .evaluate, .extract, .classify, .acceptCookies, .login, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv, .screenshot, .waitForSelector, .waitForScript, .waitForState => false,
        };
    }

    /// Reference-docs section (`zig build docs`). Exhaustive so a new tool
    /// can't ship undocumented.
    pub fn group(self: Tool) Group {
        return switch (self) {
            .goto, .search => .navigation,
            .markdown, .html, .screenshot, .tree, .links, .nodeDetails, .findElement, .interactiveElements, .structuredData, .detectForms => .reading,
            .extract, .classify, .evaluate => .extraction,
            .click, .fill, .scroll, .hover, .press, .selectOption, .setChecked, .acceptCookies, .login => .interaction,
            .waitForSelector, .waitForScript, .waitForState => .waiting,
            .getUrl, .getCookies, .getEnv, .consoleLogs => .state,
        };
    }

    pub const Definition = definitions.Definition;

    pub const Group = enum {
        navigation,
        reading,
        extraction,
        interaction,
        waiting,
        state,
    };
};

pub fn minify(comptime json: []const u8) []const u8 {
    // Cumulative: tool_defs evaluates every schema in one comptime scope.
    @setEvalBranchQuota(100_000);
    return comptime blk: {
        var buf: [json.len]u8 = undefined;
        var len: usize = 0;
        var in_string = false;
        var escaped = false;
        for (json) |c| {
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
            } else switch (c) {
                ' ', '\n', '\r', '\t' => continue,
                '"' => in_string = true,
                else => {},
            }
            buf[len] = c;
            len += 1;
        }
        const final = buf[0..len].*;
        break :blk &final;
    };
}

/// Materialized form of `definitions.of` keyed by `@backingInt(Tool)`.
/// Built at comptime by iterating every `Tool` tag — order and count
/// can't drift because both come from the enum itself.
pub const tool_defs: [@typeInfo(Tool).@"enum".field_names.len]Tool.Definition = blk: {
    var arr: [@typeInfo(Tool).@"enum".field_names.len]Tool.Definition = undefined;
    for (std.enums.values(Tool), 0..) |t, i| arr[i] = definitions.of(t);
    break :blk arr;
};

/// Comptime-built flat array of tool names, in `Tool` declaration order.
/// Use this when callers only need the names (slash-command lookup, MCP
/// `tools/list`).
pub const names: [@typeInfo(Tool).@"enum".field_names.len][]const u8 = blk: {
    const field_names = @typeInfo(Tool).@"enum".field_names;
    var arr: [field_names.len][]const u8 = undefined;
    for (field_names, 0..) |field_name, i| arr[i] = field_name;
    break :blk arr;
};

pub const ToolError = error{
    FrameNotLoaded,
    InvalidParams,
    NodeNotFound,
    NavigationFailed,
    NavigationTimeout,
    Cancelled,
    Timeout,
    InternalError,
    OutOfMemory,
};

/// LLM-facing message for a tool failure. Bare error names leave the model
/// retrying blind; spell out the recovery for errors it can act on.
pub fn errorMessage(err: ToolError) []const u8 {
    return switch (err) {
        error.NodeNotFound => "NodeNotFound: the selector or backendNodeId matched nothing on the current page. Re-inspect the page (tree/interactiveElements) for fresh node ids, or omit backendNodeId to target the document root.",
        error.FrameNotLoaded => "FrameNotLoaded: no page is loaded — call goto (or pass a url) first.",
        error.NavigationTimeout => "NavigationTimeout: no response arrived before the timeout, so the page is empty. Other sessions may be holding every connection (see --http-max-concurrent); retry goto or close idle sessions.",
        else => @errorName(err),
    };
}

/// Outcome of running a tool against the page. Operational failures (OOM,
/// missing page, invalid params) come out as Zig errors on the enclosing
/// `!ToolResult`; `is_error = true` is the in-band signal for a JS-level
/// failure (V8 caught a throw inside `evaluate`/`extract`) or any failure whose
/// message carries detail the model needs — the LLM consumes `text` either way
/// to self-correct. Non-evaluate tools always set `is_error =
/// false` on success.
pub const ToolResult = struct {
    text: []const u8,
    is_error: bool = false,
    /// The call left a different frame current, so `--save` records the
    /// navigation a read tool's `url` made rather than one it skipped.
    navigated: bool = false,
    /// Only set when the caller passed `CallOpts.inline_image`.
    image: ?lp.screenshot.Prepared = null,
    /// Resolved before the action runs, because a navigation takes the node
    /// with it.
    selector: ?[]const u8 = null,
    /// Locators the tool resolved for itself, as a JSON object merged over the
    /// call's own args when `--save` records it. A tool that asks a model
    /// which element to act on writes the answer into the script this way, so
    /// the question is asked once instead of on every replay.
    replay_args: ?[]const u8 = null,
    /// Set for the tools `Tool.reportsPageState` names.
    page_state: ?PageState = null,
    /// Set when a caller acts on an in-band failure's kind rather than only
    /// reporting its text. Implies `is_error`.
    failure: ?FailureKind = null,

    const FailureKind = enum {
        /// Telemetry counts it as `invalid_params`.
        invalid_params,
        /// The REPL falls back to a chat model for the tools that have a
        /// prompt form; every other caller just reports it.
        missing_api_key,
    };

    fn invalidParams(text: []const u8) ToolResult {
        return .{ .text = text, .is_error = true, .failure = .invalid_params };
    }
};

/// Where a call left the page. MCP serializes it as `structuredContent` so a
/// client reads the status without regexing `Navigated. HTTP 404
/// Not Found.` back apart. The transport drops null optionals rather than
/// writing them, so the matching `outputSchema` requires `url` alone.
pub const PageState = struct {
    url: []const u8,
    httpStatus: ?u16,
    title: ?[]const u8,
};

pub fn pageState(frame: *lp.Frame) PageState {
    return .{
        .url = frame.url,
        .httpStatus = frame._http_status,
        .title = frame.getTitle() catch null,
    };
}

const GotoParams = struct {
    url: [:0]const u8,
    timeout: ?u32 = null,
    waitUntil: lp.Config.WaitUntil = default_nav_wait,
};

const UrlParams = struct {
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
};

const ActionTarget = union(enum) {
    selector: []const u8,
    backend_node_id: NodeRegistry.Id,

    pub fn format(self: ActionTarget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .selector => |sel| try writer.print("selector: {s}", .{sel}),
            .backend_node_id => |id| try writer.print("backendNodeId: {d}", .{id}),
        }
    }
};

const NodeAndPage = struct { node: *DOMNode, page: *lp.Frame, target: ActionTarget };

/// What the caller can do with a result beyond its text.
pub const CallOpts = struct {
    /// The caller can hand an image to a model.
    inline_image: bool = false,
    /// Fill in `ToolResult.selector`: a registry id means nothing in a later
    /// session, so `--save` cannot replay a call that used one.
    record: bool = false,
    /// Scripts parse the text, so only model-facing callers set it.
    nav_note: bool = false,
    source: TelemetryTool.Source,
};

/// Told about every call once it returns, failures included.
pub const Observer = struct {
    context: *anyopaque,
    onCall: *const fn (context: *anyopaque, tool_name: []const u8, arguments: ?std.json.Value, result: *const ToolResult, ms: u64, frame: ?*lp.Frame) void,
};

// An inline screenshot is re-sent on every turn; keep it within what models
// consume. Files written to `path` are full size.
pub const inline_image_max_width = 1280;
pub const inline_image_max_height = 4096;

pub fn call(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    tool_name: []const u8,
    arguments: ?std.json.Value,
    opts: CallOpts,
) ToolError!ToolResult {
    const start = lp.datetime.milliTimestamp(.awake);
    const maybe_tool = std.meta.stringToEnum(Tool, tool_name);
    const result = callInner(arena, session, registry, maybe_tool, tool_name, arguments, opts);
    const id: u8 = if (maybe_tool) |t| t.telemetryId() else 0;
    session.browser.app.telemetry.recordTool(id, opts.source, telemetryOutcome(result), start);
    if (session.tool_observer) |observer| {
        const reported: ToolResult = result catch |err| .{ .text = errorMessage(err), .is_error = true };
        observer.onCall(observer.context, tool_name, arguments, &reported, lp.datetime.milliTimestamp(.awake) -| start, session.currentFrame());
    }
    return result;
}

fn telemetryOutcome(result: ToolError!ToolResult) TelemetryTool.Outcome {
    const r = result catch |err| return errorOutcome(err);
    if (r.failure == .invalid_params) return .invalid_params;
    return if (r.is_error) .is_error else .ok;
}

pub fn errorOutcome(err: ToolError) TelemetryTool.Outcome {
    return switch (err) {
        error.FrameNotLoaded => .frame_not_loaded,
        error.InvalidParams => .invalid_params,
        error.NodeNotFound => .node_not_found,
        error.NavigationFailed => .navigation_failed,
        error.NavigationTimeout => .navigation_timeout,
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.InternalError, error.OutOfMemory => .internal,
    };
}

fn callInner(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    maybe_tool: ?Tool,
    tool_name: []const u8,
    arguments: ?std.json.Value,
    opts: CallOpts,
) ToolError!ToolResult {
    // In-band so an LLM that invented a tool name (e.g. OpenAI's internal
    // `multi_tool_use.parallel` wrapper) learns the name is wrong instead of
    // retrying it with different arguments.
    const tool = maybe_tool orelse return .{
        .text = try arena.print("Unknown tool: {s}", .{tool_name}),
        .is_error = true,
    };
    if (diagnoseArgs(arena, arguments)) |msg|
        return .invalidParams(msg);
    // Must run before substituteStringArgs so the `key=="value"` secret-
    // redaction check there still triggers on PascalCase keys.
    const normalized = normalizeArgs(arena, tool, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return error.InvalidParams,
    };
    // After normalizeArgs so a PascalCase `Script` or a `null` isn't missed.
    if (diagnoseMissingRequired(arena, tool, normalized)) |msg|
        return .invalidParams(msg);
    const substituted = try substituteStringArgs(arena, tool, normalized);

    // Before dispatch, because a navigation takes the node with it. Gated on
    // `isRecorded` because `SelectorPath.build` is the expensive part of a tool
    // call and the read-only tools that take a `backendNodeId` -- tree,
    // markdown, html, nodeDetails -- would only have it thrown away.
    const selector = if (opts.record and tool.isRecorded())
        selectorForArgs(arena, session, registry, substituted)
    else
        null;

    const frame_before = if (session.currentFrame()) |f| f._frame_id else null;
    var result = dispatch(arena, session, registry, tool, substituted, opts) catch |err| {
        if (err == error.NavigationFailed) {
            if (formatNavigationError(arena, session)) |text|
                return .{ .text = text, .is_error = true };
        }
        return err;
    };
    result.selector = selector;
    if (session.currentFrame()) |frame| result.navigated = frame._frame_id != frame_before;
    if (opts.nav_note) {
        if (session.currentFrame()) |frame| {
            if (result.navigated) {
                if (try weaknessNote(arena, frame)) |n| result.text = try arena.print("{s}\n\n{s}", .{ n, result.text });
            }
            const note = if (result.navigated)
                try navErrorNote(arena, frame)
            else if (tool.navigatesToUrl())
                try movedNote(arena, substituted, frame)
            else
                null;
            if (note) |n| result.text = try arena.print("{s}\n\n{s}", .{ n, result.text });
        }
    }
    if (tool.reportsPageState()) {
        if (session.currentFrame()) |frame| result.page_state = pageState(frame);
    }
    return result;
}

/// The CSS selector for a call's `backendNodeId`, so the call can be recorded
/// in a form that still resolves in a later session.
fn selectorForArgs(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    arguments: ?std.json.Value,
) ?[]const u8 {
    const args = arguments orelse return null;
    if (args != .object) return null;
    if (args.object.contains("selector")) return null;
    const id = args.object.get("backendNodeId") orelse return null;
    if (id != .integer) return null;

    const node = registry.lookup_by_id.get(std.math.cast(NodeRegistry.Id, id.integer) orelse return null) orelse return null;
    const el = node.dom.is(Element) orelse return null;
    const frame = session.currentFrame() orelse return null;
    return selectorFor(arena, frame, el);
}

/// The simplest selector that resolves to `el` again under the first-match
/// semantics the action tools use, or null when none could be built.
fn selectorFor(arena: std.mem.Allocator, frame: *lp.Frame, el: *Element) ?[]const u8 {
    return SelectorPath.init(arena, frame).build(el) catch null;
}

fn dispatch(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    tool: Tool,
    substituted: ?std.json.Value,
    opts: CallOpts,
) ToolError!ToolResult {
    return switch (tool) {
        .goto => .{ .text = try execGoto(arena, session, registry, substituted) },
        .search => search.exec(arena, session, substituted),
        .markdown => .{ .text = try execMarkdown(arena, session, registry, substituted) },
        .html => .{ .text = try execHtml(arena, session, registry, substituted) },
        .screenshot => try execScreenshot(arena, session, registry, substituted, opts.inline_image),
        .links => .{ .text = try execLinks(arena, session, registry, substituted) },
        .tree => .{ .text = try execTree(arena, session, registry, substituted) },
        .nodeDetails => .{ .text = try execNodeDetails(arena, session, registry, substituted) },
        .interactiveElements => .{ .text = try execInteractiveElements(arena, session, registry, substituted) },
        .structuredData => .{ .text = try execStructuredData(arena, session, registry, substituted) },
        .detectForms => .{ .text = try execDetectForms(arena, session, registry, substituted) },
        .click => .{ .text = try execClick(arena, session, registry, substituted) },
        .fill => execFill(arena, session, registry, substituted),
        .scroll => .{ .text = try execScroll(arena, session, registry, substituted) },
        .waitForSelector => .{ .text = try execWaitForSelector(arena, session, registry, substituted) },
        .waitForScript => .{ .text = try execWaitForScript(arena, session, substituted) },
        .waitForState => .{ .text = try execWaitForState(arena, session, substituted) },
        .hover => .{ .text = try execHover(arena, session, registry, substituted) },
        .press => .{ .text = try execPress(arena, session, registry, substituted) },
        .selectOption => .{ .text = try execSelectOption(arena, session, registry, substituted) },
        .setChecked => .{ .text = try execSetChecked(arena, session, registry, substituted) },
        .findElement => execFindElement(arena, session, registry, substituted),
        .evaluate => execEvaluate(arena, session, registry, substituted),
        .extract => execExtract(arena, session, registry, substituted),
        .classify => execClassify(arena, session, registry, substituted),
        .acceptCookies => execAcceptCookies(arena, session, registry, substituted),
        .login => execLogin(arena, session, registry, substituted),
        .getEnv => .{ .text = try execGetEnv(arena, substituted) },
        .consoleLogs => .{ .text = try execConsoleLogs(arena, session) },
        .getUrl => .{ .text = try execGetUrl(session) },
        .getCookies => .{ .text = try execGetCookies(arena, session, substituted) },
    };
}

fn formatNavigationError(arena: std.mem.Allocator, session: *lp.Session) ?[]const u8 {
    const frame = session.currentFrame() orelse return null;
    const err = frame._last_navigate_error orelse return null;
    return arena.print("navigation failed: {s}", .{@errorName(err)}) catch null;
}

/// Run JavaScript against the current page. The script need not be
/// 0-terminated; a copy is made internally.
pub fn evalScript(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    script: []const u8,
) ToolError!ToolResult {
    const z = try arena.dupeSentinel(u8, script, 0);
    const page = try ensurePage(session, registry, null, null);
    return runEval(arena, page, z, null);
}

/// Schema-driven extraction. The schema is parsed in Zig so a syntax error
/// surfaces here instead of as a confusing V8 SyntaxError on the spliced
/// walker.
pub fn extract(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    schema_json: []const u8,
) ToolError!ToolResult {
    const trimmed = std.mem.trim(u8, schema_json, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return error.InvalidParams;
    const valid = try std.json.validate(arena, schema_json);
    if (!valid) return error.InvalidParams;

    const script = try std.mem.concatWithSentinel(arena, u8, &.{ schema_walker_prefix, schema_json, schema_walker_suffix }, 0);
    const page = try ensurePage(session, registry, null, null);
    return runEval(arena, page, script, null);
}

// The schema literal is spliced between prefix and suffix verbatim — a format
// string here would collide with the `{`/`}` throughout the walker body.
const schema_walker_prefix =
    \\(function(schema){
    \\  function valueOf(m, inner){
    \\    if (inner.fields) {
    \\      const r = {};
    \\      for (const k in inner.fields) r[k] = ext(m, inner.fields[k]);
    \\      return r;
    \\    }
    \\    if (inner.attr) {
    \\      const raw = m.getAttribute(inner.attr);
    \\      // Resolve href/src like the DOM .href/.src properties do, so extracted
    \\      // URLs are usable by goto.
    \\      if (raw !== null && (inner.attr === 'href' || inner.attr === 'src')) {
    \\        try { return new URL(raw, document.baseURI).href; } catch (e) { return raw; }
    \\      }
    \\      return raw;
    \\    }
    \\    return m.textContent.trim();
    \\  }
    \\  function ext(el, v){
    \\    if (typeof v === 'string') {
    \\      if (v === '') return el.textContent.trim();
    \\      const m = el.querySelector(v);
    \\      return m ? m.textContent.trim() : null;
    \\    }
    \\    if (Array.isArray(v)) {
    \\      const inner = typeof v[0] === 'string' ? { selector: v[0] } : v[0];
    \\      let matches = Array.from(el.querySelectorAll(inner.selector));
    \\      if (typeof inner.limit === 'number') matches = matches.slice(0, inner.limit);
    \\      return matches.map(function(m){ return valueOf(m, inner); });
    \\    }
    \\    const t = v.selector ? el.querySelector(v.selector) : el;
    \\    if (!t) return null;
    \\    return valueOf(t, v);
    \\  }
    \\  const out = {};
    \\  let any = false;
    \\  for (const k in schema) {
    \\    out[k] = ext(document, schema[k]);
    \\    const v = out[k];
    \\    // A resolved array — even empty — is a real result (e.g. a page with
    \\    // zero comments); only an all-null schema means every selector missed.
    \\    if (v !== null) any = true;
    \\  }
    \\  if (!any) throw new Error("extract: no schema selector matched any element — inspect the page with tree/markdown and retry with corrected selectors");
    \\  return JSON.stringify(out);
    \\})(
;
const schema_walker_suffix = ")";

/// The response status of the frame's own document, as `403 Forbidden`, or
/// "unknown" before any response has arrived. `Frame.httpMetadata` has carried
/// this all along and only the `fetch` CLI path ever read it, so an agent that
/// navigated into a 403 or a 404 had no way to tell and would read the error
/// page as content.
fn navStatus(arena: std.mem.Allocator, frame: *const lp.Frame) []const u8 {
    const status = frame._http_status orelse return "unknown";
    // `std.http.Status` is an enum(u10) and `_http_status` is only clamped to
    // u16 (`http.getResponseCode`), so a server answering with a 4-digit code
    // would make the cast illegal behaviour rather than an unknown phrase.
    const phrase = if (status > 599) "" else @as(std.http.Status, @fromBackingInt(@intCast(status))).phrase() orelse "";
    if (phrase.len == 0) return arena.print("{d}", .{status}) catch "unknown";
    return arena.print("{d} {s}", .{ status, phrase }) catch "unknown";
}

/// Otherwise the model takes the current page for the URL it asked for.
fn movedNote(arena: std.mem.Allocator, arguments: ?std.json.Value, frame: *const lp.Frame) !?[]const u8 {
    const args = arguments orelse return null;
    if (args != .object) return null;
    const url = switch (args.object.get("url") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (url.len == 0 or std.mem.eql(u8, url, frame.url)) return null;
    return try arena.print("The page is at {s}, not {s}: a redirect or an in-page navigation moved it, and this reads it as it is. Use goto to reload {s}.", .{ frame.url, url, url });
}

/// What a full browser would have shown that this page's reads will lack.
/// Only the signals that change what the model should do; canvas 2D is left
/// out because fingerprinting scripts paint on most pages.
fn weaknessNote(arena: std.mem.Allocator, frame: *const lp.Frame) !?[]const u8 {
    const status = &frame.page.status;
    var notes: std.ArrayList([]const u8) = .empty;
    if (status.unsupported.get(.webgl) > 0) {
        try notes.append(arena, "The page asked for WebGL, which Lightpanda does not provide: anything it renders that way is missing.");
    }
    const iframes = status.skipped.get(.iframe);
    if (iframes > 0) {
        try notes.append(arena, try arena.print("{d} iframe(s) were not loaded: subframe loading is off.", .{iframes}));
    }
    if (status.resource_challenge) |challenge| {
        try notes.append(arena, try arena.print("A {s} bot challenge blocked some of the page's own requests: content they load is missing.", .{@tagName(challenge)}));
    } else {
        const blocked = status.blocked.total();
        if (blocked > 0) {
            try notes.append(arena, try arena.print("{d} of the page's own request(s) were refused with HTTP 403/429, likely bot detection or rate limiting: content they load is missing.", .{blocked}));
        }
    }
    if (notes.items.len == 0) {
        return null;
    }
    return try std.mem.join(arena, " ", notes.items);
}

/// Error and challenge pages would otherwise read as the requested content.
fn navErrorNote(arena: std.mem.Allocator, frame: *const lp.Frame) !?[]const u8 {
    if (frame._bot_challenge) |challenge| {
        return try arena.print("Blocked by a {s} bot challenge (HTTP {s}): this is not the requested content.", .{ @tagName(challenge), navStatus(arena, frame) });
    }
    const status = frame._http_status orelse return null;
    if (status < 400) return null;
    return try arena.print("HTTP {s}: this is likely an error or rate-limit page, not the requested content.", .{navStatus(arena, frame)});
}

fn execGoto(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgs(GotoParams, arena, arguments);
    const result = try performGoto(session, registry, args.url, .{ .timeout = args.timeout, .wait_until = args.waitUntil });
    const status = if (session.currentFrame()) |frame| navStatus(arena, frame) else "unknown";
    return switch (result) {
        .completed => arena.print("Navigated. HTTP {s}.", .{status}),
        .timeout => arena.print("Navigation started (HTTP {s}) but the page did not finish loading before the timeout.", .{status}),
    } catch ToolError.InternalError;
}

/// Duped out of the client before `deinit` takes it; otherwise the model sees
/// only the error name.
pub const Failure = zenai.http.ErrorDetail;

/// `subject` failed against a remote API, with the status and message it gave.
fn apiFailed(arena: std.mem.Allocator, subject: []const u8, err: anyerror, detail: Failure) ToolError!ToolResult {
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("{s} ", .{subject}) catch return ToolError.OutOfMemory;
    writeFailure(&aw.writer, err, detail) catch return ToolError.OutOfMemory;
    return .{ .text = aw.written(), .is_error = true };
}

/// Newlines in API-provided text would break the numbered-list markdown.
pub fn writeSingleLine(w: *std.Io.Writer, text: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    var first = true;
    while (it.next()) |chunk| {
        if (!first) {
            try w.writeByte(' ');
        }
        first = false;
        try w.writeAll(chunk);
    }
}

pub fn writeFailure(w: *std.Io.Writer, err: anyerror, detail: Failure) !void {
    try w.print("failed: {s}", .{@errorName(err)});
    if (detail.status) |status| try w.print(" (HTTP {d})", .{status});
    if (detail.message) |message| {
        try w.writeAll(": ");
        try writeSingleLine(w, message);
    }
}

fn renderFrameMarkdown(arena: std.mem.Allocator, frame: *lp.Frame) ToolError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(.{ .root = frame.document.asNode() }, .{}, &aw.writer, frame) catch
        return ToolError.InternalError;
    return aw.written();
}

fn execMarkdown(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        selector: ?[]const u8 = null,
        backendNodeId: ?NodeRegistry.Id = null,
        maxBytes: ?u32 = null,
        strip: lp.dump.Opts.Strip = .{},
        url: ?[:0]const u8 = null,
        alternate: bool = false,
        timeout: ?u32 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    const timer: std.Io.Timestamp = .now(lp.io, .boot);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    if (args.alternate) {
        // The alternate stands for the whole page, like `fetch --markdown-alternate`.
        if (args.selector != null or args.backendNodeId != null) return ToolError.InvalidParams;
        const elapsed: u32 = @intCast(timer.untilNow(lp.io, .boot).toMilliseconds());
        const remaining = (args.timeout orelse default_nav_timeout_ms) -| elapsed;
        if (try readMarkdownAlternate(arena, session, page, args.maxBytes, remaining)) |text| return text;
    }

    const node = try resolveScope(session, registry, page, args.selector, args.backendNodeId);
    const state = lp.RenderTree.resolve(arena, node, args.strip, page) catch return ToolError.OutOfMemory;

    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(state, .{ .max_bytes = args.maxBytes }, &aw.writer, page) catch return ToolError.InternalError;
    return aw.written();
}

/// The page's `<link rel="alternate" type="text/markdown">`, loaded in a page
/// of its own so the current page stays where it is. Null when there is no
/// such link, the page failed, or the alternate doesn't load as markdown
/// within `timeout_ms`.
fn readMarkdownAlternate(arena: std.mem.Allocator, session: *lp.Session, frame: *lp.Frame, max_bytes: ?u32, timeout_ms: u32) ToolError!?[]const u8 {
    const page = (lp.markdown.openAlternate(arena, session, frame) catch |err| return switch (err) {
        error.OutOfMemory => ToolError.OutOfMemory,
        else => ToolError.InternalError,
    }) orelse return null;
    defer page.close();

    var runner = session.runner(.{});
    var conditions = [_]lp.Session.Runner.WaitCondition{.{ .frame_id = page.frame_id, .until = default_nav_wait }};
    // A timeout leaves the alternate unloaded, so the check below falls back
    // to the page; a failed wait is an error.
    _ = runner.waitResult(timeout_ms, &conditions) catch |err| return switch (err) {
        error.Cancelled => ToolError.Cancelled,
        error.OutOfMemory => ToolError.OutOfMemory,
        else => ToolError.InternalError,
    };

    const alternate = page.frame() orelse return null;
    if (!lp.markdown.isAlternateLoaded(alternate)) return null;
    // Say which source this is: the alternate can differ from the rendered page.
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("<!-- markdown alternate: {s} -->\n", .{alternate.url}) catch return ToolError.OutOfMemory;
    lp.markdown.dumpAlternate(alternate, max_bytes, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

/// The node a read tool works on: the selector match, the registry node, or
/// the whole document. All three live in the current frame.
fn resolveScope(session: *lp.Session, registry: *NodeRegistry, page: *lp.Frame, selector: ?[]const u8, node_id: ?NodeRegistry.Id) ToolError!*DOMNode {
    if (selector == null and node_id == null) return page.document.asNode();
    return (try resolveTarget(session, registry, selector, node_id)).node;
}

const HtmlParams = struct {
    selector: ?[]const u8 = null,
    backendNodeId: ?NodeRegistry.Id = null,
    maxBytes: ?u32 = null,
    strip: lp.dump.Opts.Strip = .{},
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
};

fn execHtml(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(HtmlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    const target = try resolveScope(session, registry, page, args.selector, args.backendNodeId);
    const state = lp.RenderTree.resolve(arena, target, args.strip, page) catch return ToolError.OutOfMemory;
    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.dump.render(state, .{ .max_bytes = args.maxBytes }, &aw.writer, page) catch return ToolError.InternalError;
    return aw.written();
}

fn execScreenshot(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value, inline_image: bool) ToolError!ToolResult {
    const Params = struct {
        path: ?[]const u8 = null,
        selector: ?[]const u8 = null,
        backendNodeId: ?NodeRegistry.Id = null,
        fullPage: bool = false,
        strip: lp.dump.Opts.Strip = .{},
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    if (args.path) |path| {
        if (!isPathSafe(path)) return .{ .text = unsafe_path_message, .is_error = true };
    } else if (!inline_image) {
        return .{ .text = "pass `path`: this client cannot display an inline image", .is_error = true };
    }
    const page = try ensurePage(session, registry, args.url, args.timeout);
    const scope = try resolveScope(session, registry, page, args.selector, args.backendNodeId);
    const state = lp.RenderTree.resolve(arena, scope, args.strip, page) catch return ToolError.OutOfMemory;
    const opts: lp.screenshot.Opts = .fromViewport(page.page.getViewport(), args.fullPage);
    var prepared = lp.screenshot.preparePng(arena, state, opts, page) catch
        return ToolError.InternalError;

    if (args.path) |path| {
        const content_height = writePng(&prepared, path) catch |err| return .{
            .text = arena.print("could not write {s}: {s}", .{ path, @errorName(err) }) catch return ToolError.OutOfMemory,
            .is_error = true,
        };
        // The renderer reports the content height; a fixed strip is its own height.
        const height = if (prepared.opts.height == 0) content_height else prepared.opts.height;
        return .{ .text = arena.print("Saved {d}x{d} PNG to {s}", .{ prepared.opts.width, height, absolutePath(arena, path) }) catch return ToolError.OutOfMemory };
    }

    prepared.fit(inline_image_max_width, inline_image_max_height) catch return ToolError.InternalError;
    return .{
        .text = arena.print("PNG, {d}x{d}", .{ prepared.opts.width, prepared.opts.height }) catch return ToolError.OutOfMemory,
        .image = prepared,
    };
}

fn writePng(prepared: *const lp.screenshot.Prepared, path: []const u8) !u32 {
    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{ .truncate = true });
    defer file.close(lp.io);
    var buf: [8 * 1024]u8 = undefined;
    var writer = file.writer(lp.io, &buf);
    const height = try prepared.write(&writer.interface);
    try writer.interface.flush();
    return height;
}

fn execLinks(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        limit: ?u32 = null,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    var links_list = lp.links.collectLinks(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;
    if (args.limit) |limit| {
        links_list = links_list[0..@min(limit, links_list.len)];
    }
    lp.links.registerNodes(links_list, registry) catch
        return ToolError.InternalError;
    return renderJson(arena, links_list, .{});
}

fn execTree(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
        backendNodeId: ?u32 = null,
        maxDepth: ?u32 = null,
        maxBytes: ?u32 = null,
        timeout: ?u32 = null,
    };
    const args = try parseArgsOrDefault(TreeParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    const root_node = (try resolveOptionalNode(registry, args.backendNodeId)) orelse page.document.asNode();
    const st = lp.SemanticTree.init(arena, root_node, registry, page, .{
        .max_depth = args.maxDepth orelse std.math.maxInt(u32) - 1,
        .max_bytes = args.maxBytes,
    }) catch return ToolError.NodeNotFound;

    var aw: std.Io.Writer.Allocating = .init(arena);
    st.textStringify(&aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execNodeDetails(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { backendNodeId: NodeRegistry.Id };
    const args = try parseArgs(Params, arena, arguments);

    const page = try requireFrame(session);

    const node = registry.lookup_by_id.get(args.backendNodeId) orelse
        return ToolError.NodeNotFound;
    const st = lp.SemanticTree.init(arena, node.dom, registry, page, .{}) catch return ToolError.NodeNotFound;
    const details = st.nodeDetails() catch return ToolError.InternalError;
    return renderJson(arena, &details, .{});
}

fn execInteractiveElements(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    lp.interactive.registerNodes(elements, registry) catch
        return ToolError.InternalError;
    return renderJson(arena, elements, .{});
}

fn execStructuredData(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    const data = lp.structured_data.collectStructuredData(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    return renderJson(arena, data, .{});
}

fn execDetectForms(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);

    const forms_data = lp.forms.collectForms(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;
    lp.forms.registerNodes(forms_data, registry) catch
        return ToolError.InternalError;
    return renderJson(arena, forms_data, .{});
}

fn execEvaluate(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        script: [:0]const u8,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        save: ?[]const u8 = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout);
    const before = session.currentFrame();
    const app_allocator = session.browser.app.allocator;

    const prelude = bridgePrelude(arena, &session.bridge_store) catch return ToolError.OutOfMemory;
    _ = try runEval(arena, page, prelude, null);

    // Block scope preserves a trailing expression's value and keeps top-level
    // `let`/`const` from leaking; top-level `await`/`return` need the async IIFE.
    const block_script = arena.printSentinel(
        "{{ {s}\n}}",
        .{args.script},
        0,
    ) catch return ToolError.OutOfMemory;
    const iife_script = arena.printSentinel(
        "(async function(){{ \"use strict\"; {s} }})()",
        .{args.script},
        0,
    ) catch return ToolError.OutOfMemory;
    var result = try runEval(arena, page, block_script, iife_script);
    if (result.is_error) return result;

    // Sync lp.* before any queued navigation tears down this JS context.
    const postlude_result: ?ToolResult = runEval(arena, page, bridge_postlude, null) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => null,
    };
    if (postlude_result) |pr| if (!pr.is_error) {
        bridgeSync(app_allocator, &session.bridge_store, pr.text) catch |err| switch (err) {
            error.OutOfMemory => return ToolError.OutOfMemory,
            else => {},
        };
    };

    // Silence on save= success so stdout pipes stay clean. Objects/arrays
    // already render as JSON; a bare string (or other non-JSON text) is
    // JSON-encoded so it round-trips to `lp.<name>`.
    if (args.save) |name| {
        const json_value = if (std.json.validate(arena, result.text) catch false)
            result.text
        else
            std.json.Stringify.valueAlloc(arena, result.text, .{}) catch return ToolError.OutOfMemory;
        bridgeStoreSet(app_allocator, &session.bridge_store, name, json_value) catch |err| switch (err) {
            error.OutOfMemory => return ToolError.OutOfMemory,
            error.InvalidJson => unreachable,
        };
        result = .{ .text = "" };
    }

    // Script may have queued a navigation (e.g. `top.location = …`).
    try awaitQueuedNavigation(session, page);
    const after = session.currentFrame() orelse return result;
    if (before == null or before.? == after) return result;

    registry.reset();
    if (result.text.len == 0) return result; // silenced save=; don't re-emit via nav suffix

    const page_title = after.getTitle() catch null;
    const text = arena.print("{s}\n(Navigated to {s}, HTTP {s}, title: {s})", .{
        result.text, after.url, navStatus(arena, after), page_title orelse "(none)",
    }) catch return ToolError.InternalError;
    return .{ .text = text };
}

fn execExtract(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        schema: []const u8,
        save: ?[]const u8 = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const result = try extract(arena, session, registry, args.schema);

    if (!result.is_error) if (args.save) |name| {
        bridgeStoreSet(session.browser.app.allocator, &session.bridge_store, name, result.text) catch |err| switch (err) {
            error.OutOfMemory => return ToolError.OutOfMemory,
            error.InvalidJson => return .{ .text = "extract: walker produced non-JSON output", .is_error = true },
        };
        return .{ .text = "" };
    };

    return result;
}

fn execClassify(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        questions: std.json.Value,
        selector: ?[]const u8 = null,
        presets: bool = false,
    };
    const args = try parseArgs(Params, arena, arguments);
    const page = try requireFrame(session);

    const node = try resolveScope(session, registry, page, args.selector, null);
    const prepared = lp.classify.prepareQuestions(arena, args.questions, args.presets) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return .{ .text = try arena.print("classify: invalid questions: {s}", .{@errorName(err)}), .is_error = true },
    };

    var response = switch (try askPage(arena, session, registry, .{
        .tool = .classify,
        .questions = prepared.questions,
        .node = node,
    })) {
        .failed => |result| return result,
        .ok => |ok| ok,
    };
    defer response.deinit();

    const formatted = zenai.typesafe.json.formatAnswers(arena, response.value, prepared) catch |err| return internalUnlessOom(err);

    return .{ .text = formatted };
}

const AskedResponse = zenai.typesafe.Client.Response(zenai.typesafe.types.AskResponse);

/// One Jev request about the current page: `.failed` carries what to tell the
/// caller, so a key that is not set or an API that is down reads the same
/// whichever tool asked.
const Asked = union(enum) {
    ok: AskedResponse,
    failed: ToolResult,
};

const Ask = struct {
    /// Names the request in an error message, and nothing else.
    tool: Tool,
    questions: zenai.typesafe.Questions,
    /// The subtree the model is shown.
    node: *DOMNode,
    state: lp.jev.StateOpts = .{},
};

fn askPage(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    ask: Ask,
) ToolError!Asked {
    const page = try requireFrame(session);
    const state = lp.jev.buildState(arena, page, ask.node, registry, ask.state) catch |err| return internalUnlessOom(err);

    var detail: Failure = .{};
    // On a helper thread, pumping here until it answers: a blocking read on
    // this thread stops the page's timers and leaves its transfers
    // unserviced while curl's own timeout keeps counting against them.
    const options: zenai.typesafe.types.AskOptions = .{};
    const pool = &session.browser.app.typesafe;
    const response = session.runPumped(zenai.typesafe.Pool.ask, .{ pool, arena, state, ask.questions, options, &detail }) catch |err| switch (err) {
        error.MissingApiKey => return .{ .failed = .{
            .text = arena.print("{s}: " ++ zenai.typesafe.env_var_name ++ " environment variable is not set", .{@tagName(ask.tool)}) catch return ToolError.OutOfMemory,
            .is_error = true,
            .failure = .missing_api_key,
        } },
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return .{ .failed = try apiFailed(arena, @tagName(ask.tool), err, detail) },
    };

    // Pumping runs the page's own scripts, and a navigation among them tears
    // down the Page that every candidate element and node id points into (see
    // `settleAction`). The answer describes a page that is no longer here.
    const now = session.currentFrame();
    if (now == null or now.? != page) {
        registry.reset();
        return .{ .failed = .{
            .text = arena.print("{s}: the page navigated while the model was asked", .{@tagName(ask.tool)}) catch return ToolError.OutOfMemory,
            .is_error = true,
        } };
    }
    return .{ .ok = response };
}

/// Anything but OOM out of one of these helpers is a bug, not a user error.
fn internalUnlessOom(err: anyerror) ToolError {
    return if (err == error.OutOfMemory) ToolError.OutOfMemory else ToolError.InternalError;
}

/// An answer we cannot read back — not one of the options we offered, or not
/// the argmax of its own probabilities.
fn unusableAnswer(arena: std.mem.Allocator, tool: Tool, err: anyerror) ToolError!ToolResult {
    return .{
        .text = arena.print("{s}: the model's answer was unusable: {s}", .{ @tagName(tool), @errorName(err) }) catch return ToolError.OutOfMemory,
        .is_error = true,
    };
}

/// Dropped rather than written as null, so a verdict reads as what happened
/// rather than as every question that could have been answered.
const compact: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// A tool's own JSON verdict, with `reason` filled in when there is one to
/// give.
fn verdict(arena: std.mem.Allocator, outcome: anytype, reason: ?[]const u8) ToolError!ToolResult {
    if (reason) |r| outcome.reason = r;
    return .{ .text = try renderJson(arena, outcome.*, compact) };
}

/// A verification ask that fails leaves us knowing what we did but not whether
/// it worked: a caller told only "ApiError" would not learn that credentials
/// went out, so the outcome is reported with the failure as its reason.
fn unverified(
    arena: std.mem.Allocator,
    outcome: anytype,
    comptime render: fn (std.mem.Allocator, @TypeOf(outcome), ?[]const u8) ToolError!ToolResult,
    failed: ToolResult,
    did: []const u8,
) ToolError!ToolResult {
    var result = try render(arena, outcome, try arena.print("{s}: {s}", .{ did, failed.text }));
    result.is_error = failed.is_error;
    result.failure = failed.failure;
    return result;
}

const settle_timeout_ms: u32 = 2000;

/// Let the page act on a click: a consent banner removes itself from a
/// handler or after a request of its own, and a sign-in form navigates. A page
/// that never goes idle is not a failure here, only one we stop waiting for.
fn settle(session: *lp.Session) ToolError!void {
    const frame = session.currentFrame() orelse return;
    lp.actions.waitForState(.networkidle, settle_timeout_ms, frame._frame_id, session) catch |err| {
        if (err == error.Cancelled) return ToolError.Cancelled;
    };
}

fn clickAndSettle(
    session: *lp.Session,
    registry: *NodeRegistry,
    node: *DOMNode,
    page: *lp.Frame,
) ToolError!void {
    const scope = beginAction(session);
    lp.actions.click(node, page) catch |err| return mapActionError(err);
    _ = try settleAction(session, registry, scope);
    try settle(session);
}

/// Controls to try before giving up: the model's pick, then its runner-up.
const max_consent_clicks = 2;

fn execAcceptCookies(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        prefer: lp.consent.Prefer = .accept,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    var outcome: lp.consent.Outcome = .{};

    // The control a previous run recorded, when it is still there: a replay
    // clicks it and asks nothing, so a saved script needs no API key.
    if (args.selector) |selector| {
        if (resolveBySelector(session, selector) catch null) |target| {
            try clickAndSettle(session, registry, target.node, target.page);
            outcome.dismissed = true;
            outcome.attempts = 1;
            outcome.selector = selector;
            return consentVerdict(arena, &outcome, "clicked the control given, without asking the model");
        }
    }

    const page = try requireFrame(session);
    const candidates = lp.choose.collect(arena, page.document.asNode(), page, registry) catch |err| return internalUnlessOom(err);
    if (candidates.len == 0) {
        return verdict(arena, &outcome, "no control on this page could be clicked");
    }
    outcome.candidates = candidates.len;

    const questions = try lp.consent.questions(arena, candidates, args.prefer);
    var response = switch (try askPage(arena, session, registry, .{
        .tool = .acceptCookies,
        .questions = questions,
        .node = page.document.asNode(),
        .state = .{ .link_urls = false, .ids = true },
    })) {
        .failed => |result| return result,
        .ok => |ok| ok,
    };
    defer response.deinit();

    outcome.consentWall = response.value.noul(lp.consent.wall_key);
    if ((outcome.consentWall orelse 0) < lp.jev.gate) {
        return verdict(arena, &outcome, "those controls are not a consent banner");
    }

    const order = lp.choose.ranked(arena, candidates, response.value, questions, lp.consent.control_key) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return unusableAnswer(arena, .acceptCookies, err),
    };
    if (order.len == 0) {
        return verdict(arena, &outcome, "no control here would dismiss the banner");
    }

    // Selectors for every control we might click, before clicking any of them:
    // the first click can navigate, which frees the nodes the rest point at.
    var tries: std.ArrayList(lp.choose.Scored) = try .initCapacity(arena, max_consent_clicks);
    var selectors: std.ArrayList([]const u8) = try .initCapacity(arena, max_consent_clicks);
    for (order[0..@min(order.len, max_consent_clicks)]) |scored| {
        const selector = selectorFor(arena, page, scored.candidate.element) orelse continue;
        tries.appendAssumeCapacity(scored);
        selectors.appendAssumeCapacity(selector);
    }

    const verify_questions = try lp.consent.verifyQuestions(arena);
    const url_before = try arena.dupe(u8, page.url);
    for (tries.items, selectors.items) |scored, selector| {
        // The runner-up was chosen on the page the first click left, and its
        // selector was built there: a structural path can resolve on this one
        // and name something else entirely. A banner here is a new question.
        if (outcome.attempts > 0 and !std.mem.eql(u8, url_before, (try requireFrame(session)).url)) {
            return consentVerdict(arena, &outcome, "clicked, and the click moved the page; ask again for the banner this one shows");
        }
        // Gone already, taken away by the click before this one.
        const target = resolveBySelector(session, selector) catch continue;

        outcome.attempts += 1;
        outcome.selector = selector;
        outcome.control = scored.candidate.name;
        outcome.confidence = scored.probability;
        try clickAndSettle(session, registry, target.node, target.page);
        outcome.dismissed = true;

        var verify = switch (try askPage(arena, session, registry, .{
            .tool = .acceptCookies,
            .questions = verify_questions,
            .node = (try requireFrame(session)).document.asNode(),
            .state = .{ .link_urls = false },
        })) {
            .failed => |failed| return unverified(arena, &outcome, consentVerdict, failed, "clicked it, but could not check whether the banner went"),
            .ok => |ok| ok,
        };
        defer verify.deinit();

        outcome.consentWallAfter = verify.value.noul(lp.consent.wall_key);
        if ((outcome.consentWallAfter orelse 1) < lp.jev.gate) {
            outcome.verified = true;
            break;
        }
    }
    if (outcome.attempts == 0) {
        return verdict(arena, &outcome, "no selector could be built for the control the model picked");
    }
    return consentVerdict(arena, &outcome, if (outcome.verified) null else "clicked, but the banner is still there");
}

fn consentVerdict(arena: std.mem.Allocator, outcome: *lp.consent.Outcome, reason: ?[]const u8) ToolError!ToolResult {
    var result = try verdict(arena, outcome, reason);
    if (outcome.selector) |selector| {
        result.replay_args = try renderJson(arena, .{ .selector = selector }, compact);
    }
    return result;
}

const LoginParams = struct {
    password: []const u8,
    username: ?[]const u8 = null,
    usernameSelector: ?[]const u8 = null,
    passwordSelector: ?[]const u8 = null,
    submitSelector: ?[]const u8 = null,
    /// Report which fields would be used and type nothing, so the picks can
    /// be scored on a real page without sending credentials.
    decideOnly: bool = false,
};

/// Which element plays which part on the page as it stands, and where it is.
const Decided = union(enum) {
    ok: struct {
        page: *lp.Frame,
        picks: lp.login.Picks,
        /// The identifier field, the password field and the control that
        /// submits them, as selectors resolved before anything is typed: a
        /// submit can navigate and free every node the picks point at.
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
        submit: ?[]const u8 = null,
        candidates: usize = 0,
    },
    failed: ToolResult,
};

/// The rules' answer where they had one, the model's where they did not — one
/// request, or none when the markup left nothing open. Run again on the page an
/// identifier-first submit returns, where the password finally appears.
fn decideLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    wanted: lp.login.Wanted,
    outcome: *lp.login.Outcome,
) ToolError!Decided {
    const page = try requireFrame(session);
    const candidates = lp.choose.collect(arena, page.document.asNode(), page, registry) catch |err| return internalUnlessOom(err);
    if (candidates.len == 0) {
        return .{ .failed = try verdict(arena, outcome, "nothing on this page can be filled in") };
    }

    const questions = try lp.login.questions(arena, candidates, wanted);
    var response = switch (try askPage(arena, session, registry, .{
        .tool = .login,
        .questions = questions,
        .node = page.document.asNode(),
        .state = .{ .link_urls = false, .ids = true },
    })) {
        .failed => |result| return .{ .failed = result },
        .ok => |ok| ok,
    };
    defer response.deinit();
    outcome.calls += 1;

    const picks = lp.login.picks(arena, candidates, questions, response.value) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return .{ .failed = try unusableAnswer(arena, .login, err) },
    };

    return .{ .ok = .{
        .page = page,
        .picks = picks,
        .user = if (picks.user) |field| selectorFor(arena, page, field.element) else null,
        .password = if (picks.password) |field| selectorFor(arena, page, field.element) else null,
        .submit = submitSelector(arena, page, picks),
        .candidates = candidates.len,
    } };
}

/// The control that submits the sign-in form — null when Enter in the field is
/// the better act, because none was picked or the one picked sits outside the
/// field's own form and so submits something else, whatever it is labelled.
fn submitSelector(arena: std.mem.Allocator, page: *lp.Frame, picks: lp.login.Picks) ?[]const u8 {
    const control = picks.submit orelse return null;
    const field = picks.password orelse picks.user orelse return null;
    if (!lp.login.sameForm(field.element, control.element)) return null;
    return selectorFor(arena, page, control.element);
}

/// Not the model's decision to make, whatever it picked: a password goes into
/// an `input[type=password]` on a form that posts over TLS, or nowhere.
fn credentialRefusal(page: *lp.Frame, picks: lp.login.Picks) ?[]const u8 {
    if (picks.password) |field| {
        if (!lp.login.isPasswordField(field.element)) {
            return "the field picked for the password is not an input[type=password]";
        }
    }
    if (picks.user) |field| {
        if (lp.login.isPasswordField(field.element)) {
            return "the field picked for the username is a password input";
        }
    }
    if (picks.password orelse picks.user) |field| {
        if (lp.login.insecureAction(page, field.element)) {
            return "this form posts to a plaintext http:// URL; refusing to send credentials";
        }
    }
    return null;
}

fn execLogin(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const args = try parseArgs(LoginParams, arena, arguments);
    var outcome: lp.login.Outcome = .{};

    // The fields a previous run recorded: fill them and submit, with no model
    // call, so a saved script needs no API key.
    if (args.passwordSelector != null or args.usernameSelector != null) {
        return replayLogin(arena, session, registry, args, &outcome);
    }

    // Which field takes the identifier cannot matter when there is none to type.
    var decided = switch (try decideLogin(arena, session, registry, .{ .user = args.username != null }, &outcome)) {
        .failed => |result| return result,
        .ok => |ok| ok,
    };

    if (decided.picks.user == null and decided.picks.password == null) {
        return verdict(arena, &outcome, "no sign-in field on this page");
    }
    if (args.username != null and decided.picks.user == null) {
        return verdict(arena, &outcome, "could not tell which field takes the username");
    }
    outcome.candidates = decided.candidates;
    if (credentialRefusal(decided.page, decided.picks)) |reason| {
        return verdict(arena, &outcome, reason);
    }
    if (args.decideOnly) {
        outcome.usernameSelector = decided.user;
        outcome.passwordSelector = decided.password;
        outcome.submitSelector = decided.submit;
        return verdict(arena, &outcome, "decided only, nothing was typed or submitted");
    }
    if (decided.picks.password == null and !decided.picks.multi_step) {
        return verdict(arena, &outcome, "no password field, and the page does not ask for one on a later step");
    }

    if (args.username) |username| {
        const selector = decided.user.?;
        try fillBySelector(session, registry, selector, username);
        outcome.usernameSelector = selector;
    }

    if (decided.picks.password == null) {
        // Identifier first: submit what we have, then look for the password on
        // the page that comes back. Where it lives is the only thing still
        // open there, so nothing else is asked about again.
        try submitLogin(session, registry, decided.submit, decided.user, &outcome);
        decided = switch (try decideLogin(arena, session, registry, .{ .user = false, .multi_step = false }, &outcome)) {
            .failed => |result| return result,
            .ok => |ok| ok,
        };
        if (decided.picks.password == null) {
            return verdict(arena, &outcome, "submitted the username, but the next page shows no password field");
        }
        if (credentialRefusal(decided.page, decided.picks)) |reason| {
            return verdict(arena, &outcome, reason);
        }
    }

    const password_selector = decided.password orelse {
        return verdict(arena, &outcome, "no selector could be built for the password field");
    };
    try fillBySelector(session, registry, password_selector, args.password);
    outcome.passwordSelector = password_selector;

    try submitLogin(session, registry, decided.submit, password_selector, &outcome);
    return verifyLogin(arena, session, registry, &outcome);
}

/// By selector, so a replay repeats what we did.
fn fillBySelector(
    session: *lp.Session,
    registry: *NodeRegistry,
    selector: []const u8,
    value: []const u8,
) ToolError!void {
    const target = try resolveBySelector(session, selector);
    const scope = beginAction(session);
    lp.actions.fill(target.node, value, target.page) catch |err| return mapActionError(err);
    _ = try settleAction(session, registry, scope);
}

fn submitLogin(
    session: *lp.Session,
    registry: *NodeRegistry,
    submit: ?[]const u8,
    field: ?[]const u8,
    outcome: *lp.login.Outcome,
) ToolError!void {
    if (submit) |selector| {
        if (resolveBySelector(session, selector) catch null) |target| {
            try clickAndSettle(session, registry, target.node, target.page);
            outcome.submitSelector = selector;
            outcome.submitted = true;
            return;
        }
    }

    const target = try resolveBySelector(session, field orelse return);
    const scope = beginAction(session);
    lp.actions.press(target.node, "Enter", target.page) catch |err| return mapActionError(err);
    _ = try settleAction(session, registry, scope);
    try settle(session);
    outcome.pressedEnter = true;
    outcome.submitted = true;
}

/// The page's own verdict on whether the sign-in worked. A failure is reported
/// and never retried: a second attempt on a wrong password is how accounts get
/// locked, and that call belongs to whoever owns the account.
fn verifyLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    outcome: *lp.login.Outcome,
) ToolError!ToolResult {
    var response = switch (try askPage(arena, session, registry, .{
        .tool = .login,
        .questions = try lp.login.verifyQuestions(arena),
        .node = (try requireFrame(session)).document.asNode(),
        .state = .{ .link_urls = false },
    })) {
        .failed => |failed| return unverified(arena, outcome, loginVerdict, failed, "submitted, but could not check whether the sign-in worked"),
        .ok => |ok| ok,
    };
    defer response.deinit();
    outcome.calls += 1;

    outcome.loginWall = response.value.noul(lp.login.wall_key);
    outcome.errorPage = response.value.noul(lp.login.error_key);
    outcome.loggedIn = (outcome.loginWall orelse 1) < lp.jev.gate and (outcome.errorPage orelse 1) < lp.jev.gate;
    return loginVerdict(arena, outcome, if (outcome.loggedIn) null else "submitted, but the page still shows a sign-in form or an error");
}

fn loginVerdict(arena: std.mem.Allocator, outcome: *lp.login.Outcome, reason: ?[]const u8) ToolError!ToolResult {
    var result = try verdict(arena, outcome, reason);
    if (outcome.passwordSelector != null or outcome.usernameSelector != null) {
        result.replay_args = try renderJson(arena, .{
            .usernameSelector = outcome.usernameSelector,
            .passwordSelector = outcome.passwordSelector,
            .submitSelector = outcome.submitSelector,
        }, compact);
    }
    return result;
}

/// The recorded form: fill the fields a previous run named and submit, with no
/// model call and no verification — a replay repeats a decision, it does not
/// make one.
fn replayLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    args: LoginParams,
    outcome: *lp.login.Outcome,
) ToolError!ToolResult {
    if (args.usernameSelector) |selector| {
        const username = args.username orelse {
            return verdict(arena, outcome, "usernameSelector was given without a username");
        };
        try fillBySelector(session, registry, selector, username);
        outcome.usernameSelector = selector;
    }
    if (args.passwordSelector) |selector| {
        // A recorded identifier-first login names both fields, and the
        // password's is not on this page yet: repeat the submit that raised it.
        if ((resolveBySelector(session, selector) catch null) == null and outcome.usernameSelector != null) {
            try submitLogin(session, registry, args.submitSelector, args.usernameSelector, outcome);
        }
        const target = try resolveBySelector(session, selector);
        const element = target.node.is(Element) orelse return ToolError.InvalidParams;
        if (!lp.login.isPasswordField(element)) {
            return verdict(arena, outcome, "passwordSelector does not name an input[type=password]");
        }
        if (lp.login.insecureAction(target.page, element)) {
            return verdict(arena, outcome, "this form posts to a plaintext http:// URL; refusing to send credentials");
        }
        try fillBySelector(session, registry, selector, args.password);
        outcome.passwordSelector = selector;
    }

    try submitLogin(session, registry, args.submitSelector, args.passwordSelector orelse args.usernameSelector, outcome);
    return loginVerdict(arena, outcome, if (args.passwordSelector == null)
        "filled the username and submitted, without asking the model; no passwordSelector was given, so no password was typed"
    else
        "filled the fields given, without asking the model");
}

const eval_promise_timeout_ms: u32 = 30_000;

/// Runs `fallback` only if `script` fails to *compile* — a compile failure ran
/// nothing, so retrying is safe; a runtime throw keeps `script`'s error.
fn runEval(arena: std.mem.Allocator, page: *lp.Frame, script: [:0]const u8, fallback: ?[:0]const u8) ToolError!ToolResult {
    var ls: lp.js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(script, null) catch |err| {
        if (err == error.CompilationError) if (fallback) |fb| return runEval(arena, page, fb, null);
        return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true };
    };

    if (js_result.isPromise()) {
        const promise = js_result.toPromise();
        promise.markAsHandled();

        var runner = page._session.runner(.{});
        const timer: std.Io.Timestamp = .now(lp.io, .boot);
        while (promise.state() == .pending) {
            const elapsed_ms: u32 = @intCast(timer.untilNow(lp.io, .boot).toMilliseconds());
            if (elapsed_ms >= eval_promise_timeout_ms) {
                return .{ .text = "promise: timed out waiting for resolution", .is_error = true };
            }
            const budget = @min(eval_promise_timeout_ms - elapsed_ms, 50);
            _ = runner.tickForFrame(page._frame_id, budget, .{ .until = .done }) catch |err| switch (err) {
                error.Cancelled => return .{ .text = "promise: cancelled", .is_error = true },
                else => return .{ .text = "promise: tick failed", .is_error = true },
            };
        }

        const settled = promise.result();
        const rejected = promise.state() == .rejected;
        // No-return async IIFE → undefined → silence, so pipes stay clean.
        if (!rejected and settled.isUndefined()) return .{ .text = "" };
        const text = (if (rejected) settled.toStringSliceWithAlloc(arena) else evalResultText(arena, settled)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true },
        };
        return .{ .text = text, .is_error = rejected };
    }

    const text = evalResultText(arena, js_result) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true },
    };
    return .{ .text = text };
}

/// Objects/arrays serialize as JSON so `return obj` prints data, not
/// `[object Object]`; errors and primitives keep their string form.
fn evalResultText(arena: std.mem.Allocator, value: lp.js.Value) ![]u8 {
    if (value.isObject() and !value.isFunction() and !value.isNativeError()) {
        return value.toJson(arena);
    }
    return value.toStringSliceWithAlloc(arena);
}

fn formatJsError(arena: std.mem.Allocator, try_catch: *lp.js.TryCatch, err: anyerror) error{OutOfMemory}![]const u8 {
    const caught = try_catch.caughtOrError(arena, err);
    var aw: std.Io.Writer.Allocating = .init(arena);
    caught.format(&aw.writer) catch |fmt_err| switch (fmt_err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.written();
}

const BridgeStore = std.StringHashMapUnmanaged([]const u8);

/// Stored values are already JSON; splice them straight into the literal
/// instead of round-tripping through json.Value.
fn bridgePrelude(arena: std.mem.Allocator, store: *const BridgeStore) ![:0]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("globalThis.lp = {");
    var it = store.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) try aw.writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(kv.key_ptr.*, .{}, &aw.writer);
        try aw.writer.writeByte(':');
        try aw.writer.writeAll(kv.value_ptr.*);
    }
    try aw.writer.writeAll("};");
    return arena.dupeSentinel(u8, aw.written(), 0);
}

const bridge_postlude: [:0]const u8 = "JSON.stringify(globalThis.lp)";

/// Drops keys missing from the postlude so `delete lp.foo` propagates.
fn bridgeSync(allocator: std.mem.Allocator, store: *BridgeStore, postlude_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, postlude_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const new_obj = parsed.value.object;

    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(allocator);
    var key_it = store.keyIterator();
    while (key_it.next()) |k| {
        if (!new_obj.contains(k.*)) try to_remove.append(allocator, k.*);
    }
    for (to_remove.items) |k| {
        if (store.fetchRemove(k)) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
    }

    var it = new_obj.iterator();
    while (it.next()) |entry| {
        var val_aw: std.Io.Writer.Allocating = .init(allocator);
        defer val_aw.deinit();
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &val_aw.writer);
        // Trusted JSON path: value was just stringified from a parsed Value.
        try bridgeStorePut(allocator, store, entry.key_ptr.*, val_aw.written());
    }
}

fn bridgeStoreSet(allocator: std.mem.Allocator, store: *BridgeStore, name: []const u8, json_value: []const u8) !void {
    if (store.getPtr(name)) |slot| {
        if (std.mem.eql(u8, slot.*, json_value)) return;
        if (!try std.json.validate(allocator, json_value)) return error.InvalidJson;
        const new_val = try allocator.dupe(u8, json_value);
        allocator.free(slot.*);
        slot.* = new_val;
        return;
    }
    if (!try std.json.validate(allocator, json_value)) return error.InvalidJson;
    try bridgeStorePut(allocator, store, name, json_value);
}

/// Same as bridgeStoreSet but skips JSON validation. Use only when the
/// caller already produced canonical JSON (e.g. via json.Stringify.value).
fn bridgeStorePut(allocator: std.mem.Allocator, store: *BridgeStore, name: []const u8, json_value: []const u8) !void {
    if (store.getPtr(name)) |slot| {
        if (std.mem.eql(u8, slot.*, json_value)) return;
        const new_val = try allocator.dupe(u8, json_value);
        allocator.free(slot.*);
        slot.* = new_val;
        return;
    }
    const key_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(key_owned);
    const val_owned = try allocator.dupe(u8, json_value);
    errdefer allocator.free(val_owned);
    try store.put(allocator, key_owned, val_owned);
}

/// Resolve a target element from either a CSS selector or a backendNodeId.
fn resolveTarget(
    session: *lp.Session,
    registry: *NodeRegistry,
    selector: ?[]const u8,
    backend_node_id: ?NodeRegistry.Id,
) ToolError!NodeAndPage {
    if (selector) |sel| return resolveBySelector(session, sel);
    if (backend_node_id) |nid| return resolveNodeAndPage(session, registry, nid);
    return ToolError.InvalidParams;
}

/// Look up an optional DOM node by backendNodeId. Returns null when no id was
/// supplied, errors when the id doesn't resolve.
fn resolveOptionalNode(registry: *NodeRegistry, backend_node_id: ?NodeRegistry.Id) ToolError!?*DOMNode {
    const id = backend_node_id orelse return null;
    const node = registry.lookup_by_id.get(id) orelse return ToolError.NodeNotFound;
    return node.dom;
}

fn mapActionError(err: anytype) ToolError {
    if (err == error.InvalidNodeType) return ToolError.InvalidParams;
    log.debug(.browser, "action error", .{ .err = @errorName(err) });
    return ToolError.InternalError;
}

/// If the previous action queued a navigation (form submit, link click,
/// Enter on an input), drive the runner until it completes or times out.
fn awaitQueuedNavigation(session: *lp.Session, frame: *lp.Frame) ToolError!void {
    // Runner waits are keyed by Page root (a popup lives on its opener's
    // Page). Read it before processing: a synthetic root navigation frees
    // the Page in place.
    const root_frame_id = frame.page.frame._frame_id;
    const navigated = session.processQueuedNavigation() catch return ToolError.InternalError;
    if (navigated == false) {
        return;
    }
    var runner = session.runner(.{});
    // `.done` never arrives on a page with background timers or polling.
    runner.waitForFrame(root_frame_id, 10000, .{ .until = .networkidle }) catch |err|
        return if (err == error.Cancelled) ToolError.Cancelled else ToolError.NavigationFailed;
}

fn formatActionResult(
    arena: std.mem.Allocator,
    prefix: []const u8,
    target: ActionTarget,
    suffix: []const u8,
) ToolError![]const u8 {
    return arena.print("{s} ({f}){s}", .{ prefix, target, suffix }) catch ToolError.InternalError;
}

/// What `finalizeAction` compares against; take it before the action runs.
const ActionScope = struct {
    frame: ?*lp.Frame,
    popups: usize,
};

fn beginAction(session: *lp.Session) ActionScope {
    const frame = session.currentFrame();
    return .{ .frame = frame, .popups = if (frame) |f| f.page.popups.items.len else 0 };
}

/// Where a settled action left the page.
const Settled = struct {
    frame: *lp.Frame,
    /// What the settle itself did that the caller's own result would not
    /// otherwise mention.
    note: []const u8 = "",
};

/// Finish a state-changing action: drain any queued navigation it triggered,
/// drop node ids a frame swap invalidated, and follow a window it opened.
/// `finalizeAction` adds the prose a single-action tool reports; a tool that
/// writes its own result calls this directly.
fn settleAction(session: *lp.Session, registry: *NodeRegistry, scope: ActionScope) ToolError!Settled {
    const before = scope.frame;
    if (before) |b| {
        try awaitQueuedNavigation(session, b);
    }
    var page = try requireFrame(session);
    // A queued navigation that swaps the root frame tears down the previous
    // Page (`Session.replaceRootImmediate` / `commitPendingPage`), so every
    // DOMNode pointer in the registry now dangles. Drop the registry so the
    // next action can't dereference freed memory.
    if (before != null and before.? != page) registry.reset();

    var note: []const u8 = "";
    if (page.page.popups.items.len > scope.popups) {
        // The action opened a new window (target=_blank or window.open).
        // Follow it, as a user whose click opened a tab would.
        var runner = session.runner(.{});
        runner.waitForFrame(page.page.frame._frame_id, 10000, .{ .until = .networkidle }) catch |err|
            return if (err == error.Cancelled) ToolError.Cancelled else ToolError.NavigationFailed;
        page = try requireFrame(session);
        const popups = page.page.popups.items;
        if (popups.len > scope.popups) {
            page = popups[popups.len - 1];
            session.followPopup(page._frame_id);
            registry.reset();
            note = " Opened a new window; tools now act on it.";
        }
    }

    return .{ .frame = page, .note = note };
}

/// `settleAction`, plus the resulting page URL and title tagged onto `body` so
/// the caller (LLM, MCP client) can see whether the action navigated.
fn finalizeAction(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, scope: ActionScope, body: []const u8) ToolError![]const u8 {
    const settled = try settleAction(session, registry, scope);
    const page_title = settled.frame.getTitle() catch null;
    return arena.print("{s}.{s} Page url: {s}, HTTP {s}, title: {s}", .{
        body, settled.note, settled.frame.url, navStatus(arena, settled.frame), page_title orelse "(none)",
    }) catch ToolError.InternalError;
}

fn execClick(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?NodeRegistry.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    const scope = beginAction(session);

    lp.actions.click(resolved.node, resolved.page) catch |err| return mapActionError(err);

    const body = try formatActionResult(arena, "Clicked element", resolved.target, "");
    return finalizeAction(arena, session, registry, scope, body);
}

fn execFill(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        backendNodeId: ?NodeRegistry.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8,
    };
    const args = try parseArgs(Params, arena, arguments);
    const raw_text = args.value;
    const text = try substituteEnvVars(arena, raw_text);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    // The same refusal `login` makes, on the path the driver guidance sends a
    // model down when `login` declines: a password typed into a form an https
    // page posts in the clear goes out in the clear.
    if (resolved.node.is(Element)) |element| {
        if (lp.login.isPasswordField(element) and lp.login.insecureAction(resolved.page, element)) {
            return .{
                .text = "this form posts to a plaintext http:// URL; refusing to fill a password into it",
                .is_error = true,
            };
        }
    }

    const scope = beginAction(session);

    lp.actions.fill(resolved.node, text, resolved.page) catch |err| return mapActionError(err);

    // Show the original reference (e.g. $LP_PASSWORD) in the result, not the resolved value
    const suffix = arena.print(" with \"{s}\"", .{raw_text}) catch return ToolError.InternalError;
    const body = try formatActionResult(arena, "Filled element", resolved.target, suffix);
    return .{ .text = try finalizeAction(arena, session, registry, scope, body) };
}

fn execScroll(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?NodeRegistry.Id = null,
        selector: ?[]const u8 = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    const scope = beginAction(session);
    const resolved: ?NodeAndPage = if (args.selector != null or args.backendNodeId != null)
        try resolveTarget(session, registry, args.selector, args.backendNodeId)
    else
        null;
    const page = if (resolved) |r| r.page else try requireFrame(session);

    const result = lp.actions.scroll(if (resolved) |r| r.node else null, args.x, args.y, page) catch |err| return mapActionError(err);

    const body = (switch (result.target) {
        .window => arena.print("Scrolled window to x: {d}, y: {d}", .{ result.x, result.y }),
        .node => arena.print("Scrolled element ({f}) to x: {d}, y: {d}", .{
            resolved.?.target,
            result.x,
            result.y,
        }),
        .container => |container| blk: {
            const registered = registry.register(container) catch return ToolError.InternalError;
            break :blk arena.print("Scrolled scroll container ({f}) of element ({f}) to x: {d}, y: {d}", .{
                ActionTarget{ .backend_node_id = registered.id },
                resolved.?.target,
                result.x,
                result.y,
            });
        },
    }) catch return ToolError.InternalError;
    return finalizeAction(arena, session, registry, scope, body);
}

/// Default timeout for the `waitFor*` tools — short, since they wait on an
/// already-loaded page rather than a full navigation (which uses 10000).
const default_wait_timeout_ms: u32 = 5000;

/// A wait entered before `load` also inherits the nav budget: a post-load
/// selector keeps the wall time it had when `goto` waited for `load` itself.
/// Shared with CDP's `LP.waitForSelector`, which fronts the same action.
pub fn defaultWaitTimeout(frame: *const lp.Frame) u32 {
    if (frame._load_state == .complete) return default_wait_timeout_ms;
    return default_nav_timeout_ms + default_wait_timeout_ms;
}

fn execWaitForSelector(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = try parseArgs(Params, arena, arguments);

    const frame = try requireFrame(session);

    const timeout_ms = args.timeout orelse defaultWaitTimeout(frame);

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, frame._frame_id, session) catch |err| switch (err) {
        error.InvalidSelector => return ToolError.InvalidParams,
        error.Cancelled => return ToolError.Cancelled,
        // Timeout w/o a match: same outcome as `/hover selector=…` on a missing
        // node — surface `NodeNotFound` so the LLM sees a consistent signal.
        error.Timeout => return ToolError.NodeNotFound,
        else => {
            log.debug(.browser, "waitForSelector error", .{ .err = @errorName(err) });
            return ToolError.InternalError;
        },
    };

    const registered = registry.register(node) catch return ToolError.InternalError;
    return arena.print("Element found. backendNodeId: {d}", .{registered.id}) catch return ToolError.InternalError;
}

fn execWaitForScript(arena: std.mem.Allocator, session: *lp.Session, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        script: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = try parseArgs(Params, arena, arguments);

    const frame = try requireFrame(session);

    const timeout_ms = args.timeout orelse defaultWaitTimeout(frame);

    lp.actions.waitForScript(args.script, timeout_ms, frame._frame_id, session) catch |err| switch (err) {
        error.Cancelled => return ToolError.Cancelled,
        error.Timeout => return ToolError.Timeout,
        error.ScriptError => return ToolError.InvalidParams,
        else => {
            log.debug(.browser, "waitForScript error", .{ .err = @errorName(err) });
            return ToolError.InternalError;
        },
    };

    // script may have queued a navigation (e.g. top.location=…); drain it so
    // the next command reads post-navigation state
    try awaitQueuedNavigation(session, frame);

    return "Script returned truthy.";
}

fn execWaitForState(arena: std.mem.Allocator, session: *lp.Session, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        state: lp.Config.WaitUntil,
        timeout: ?u32 = null,
    };
    const args = try parseArgs(Params, arena, arguments);

    const frame = try requireFrame(session);

    const timeout_ms = args.timeout orelse default_wait_timeout_ms;

    lp.actions.waitForState(args.state, timeout_ms, frame._frame_id, session) catch |err| switch (err) {
        error.Cancelled => return ToolError.Cancelled,
        error.Timeout => return ToolError.Timeout,
        else => {
            log.debug(.browser, "waitForState error", .{ .err = @errorName(err) });
            return ToolError.InternalError;
        },
    };

    return arena.print("Page reached {s}.", .{@tagName(args.state)}) catch return ToolError.InternalError;
}

fn execHover(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?NodeRegistry.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    const scope = beginAction(session);

    lp.actions.hover(resolved.node, resolved.page) catch |err| return mapActionError(err);

    const body = try formatActionResult(arena, "Hovered element", resolved.target, "");
    return finalizeAction(arena, session, registry, scope, body);
}

fn execPress(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        key: []const u8,
        selector: ?[]const u8 = null,
        backendNodeId: ?NodeRegistry.Id = null,
    };
    const args = try parseArgs(Params, arena, arguments);

    var page: *lp.Frame = undefined;
    var target_node: ?*DOMNode = null;
    if (args.selector) |sel| {
        const resolved = try resolveBySelector(session, sel);
        page = resolved.page;
        target_node = resolved.node;
    } else {
        page = try requireFrame(session);
        target_node = try resolveOptionalNode(registry, args.backendNodeId);
    }

    const scope = beginAction(session);

    lp.actions.press(target_node, args.key, page) catch |err| return mapActionError(err);

    // Pressing Enter on a form input triggers implicit form submission;
    // `finalizeAction` drains the queued navigation before tagging the body.
    const body = arena.print("Pressed key '{s}'", .{args.key}) catch return ToolError.InternalError;
    return finalizeAction(arena, session, registry, scope, body);
}

fn execSelectOption(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?NodeRegistry.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    const scope = beginAction(session);

    lp.actions.selectOption(resolved.node, args.value, resolved.page) catch |err| return mapActionError(err);

    const prefix = arena.print("Selected option '{s}'", .{args.value}) catch return ToolError.InternalError;
    const body = try formatActionResult(arena, prefix, resolved.target, "");
    return finalizeAction(arena, session, registry, scope, body);
}

fn execSetChecked(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?NodeRegistry.Id = null,
        selector: ?[]const u8 = null,
        checked: bool = true,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    const scope = beginAction(session);

    lp.actions.setChecked(resolved.node, args.checked, resolved.page) catch |err| return mapActionError(err);

    const state_str: []const u8 = if (args.checked) "checked" else "unchecked";
    const suffix = arena.print(" to {s}", .{state_str}) catch return ToolError.InternalError;
    const body = try formatActionResult(arena, "Set element", resolved.target, suffix);
    return finalizeAction(arena, session, registry, scope, body);
}

fn execFindElement(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        role: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);

    if (args.role == null and args.name == null) return ToolError.InvalidParams;

    const page = try requireFrame(session);

    var name_filter: ?lp.interactive.Name = null;
    defer if (name_filter) |nf| switch (nf) {
        .regex => |re| re.deinit(),
        .substring => {},
    };
    if (args.name) |name| {
        if (regexLiteral(name)) |lit| {
            var options: lp.Regex.Options = .{ .case_insensitive = true, .unicode = true };
            for (lit.flags) |flag| switch (flag) {
                'i', 'u' => {},
                's' => options.dot_all = true,
                'm' => options.multiline = true,
                else => return .{
                    .text = try arena.print("findElement: unsupported regex flag '{c}' in '{s}'", .{ flag, name }),
                    .is_error = true,
                },
            };
            var diag: lp.Regex.Diagnostic = .{};
            const regex = session.browser.app.regex_context.compile(lit.body, options, &diag) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRegex => return .{
                    .text = try arena.print("findElement: invalid name regex '{s}': {s} at offset {d}", .{ lit.body, diag.message(), diag.offset }),
                    .is_error = true,
                },
            };
            name_filter = .{ .regex = regex };
        } else {
            name_filter = .{ .substring = name };
        }
    }

    const matched = lp.interactive.findInteractiveElements(page.document.asNode(), arena, page, .{
        .role = args.role,
        .name = name_filter,
    }) catch return ToolError.InternalError;

    lp.interactive.registerNodes(matched, registry) catch
        return ToolError.InternalError;
    return .{ .text = try renderJson(arena, matched, .{}) };
}

const RegexLiteral = struct {
    body: []const u8,
    flags: []const u8,
};

/// A JavaScript `/body/flags` literal, or null for plain text. A name really
/// written as `/foo/` still matches itself, the search being unanchored.
fn regexLiteral(text: []const u8) ?RegexLiteral {
    if (text.len == 0 or text[0] != '/') return null;
    const close = std.mem.findScalarLast(u8, text, '/') orelse return null;
    if (close < 2) return null;
    const flags = text[close + 1 ..];
    for (flags) |flag| {
        if (std.mem.findScalar(u8, "dgimsuvy", flag) == null) return null;
    }
    return .{ .body = text[1..close], .flags = flags };
}

const testing = @import("../testing.zig");

test "regexLiteral" {
    for ([_][]const u8{ "foo", "/", "//", "//i", "/foo", "/foo/ bar", "/usr/bin" }) |text| {
        try std.testing.expectEqual(null, regexLiteral(text));
    }

    const plain = regexLiteral("/foo/").?;
    try std.testing.expectEqualStrings("foo", plain.body);
    try std.testing.expectEqualStrings("", plain.flags);

    const flagged = regexLiteral("/a/b/gi").?;
    try std.testing.expectEqualStrings("a/b", flagged.body);
    try std.testing.expectEqualStrings("gi", flagged.flags);
}

fn execGetEnv(arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { name: ?[]const u8 = null };
    const args = try parseArgsOrDefault(Params, arena, arguments);

    if (args.name) |name| {
        if (lookupLpEnv(name)) |value| return value;
        return arena.print("Environment variable '{s}' is not set", .{name}) catch ToolError.InternalError;
    }

    const env_names = lpEnvNames(arena) catch return ToolError.InternalError;
    return formatLpEnvNames(arena, env_names);
}

fn formatLpEnvNames(arena: std.mem.Allocator, env_names: []const []const u8) ToolError![]const u8 {
    if (env_names.len == 0) return "No LP_* environment variables are set.";
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("LP_* environment variables ({d}):\n", .{env_names.len}) catch return ToolError.InternalError;
    for (env_names) |n| {
        aw.writer.print("  {s}\n", .{n}) catch return ToolError.InternalError;
    }
    return aw.written();
}

fn execConsoleLogs(arena: std.mem.Allocator, session: *lp.Session) ToolError![]const u8 {
    const text = session.drainConsoleMessages();
    if (text.len == 0) return "No console messages.";
    return arena.dupe(u8, text) catch ToolError.InternalError;
}

fn execGetUrl(session: *lp.Session) ToolError![]const u8 {
    const page = try requireFrame(session);
    return page.url;
}

fn execGetCookies(arena: std.mem.Allocator, session: *lp.Session, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { url: ?[]const u8 = null, all: bool = false };
    const args = try parseArgsOrDefault(Params, arena, arguments);

    const jar = &session.cookie_jar;
    if (jar.len == 0) return "No cookies.";

    const filter_url: ?[:0]const u8 = blk: {
        if (args.all) break :blk null;
        if (args.url) |u| break :blk arena.dupeSentinel(u8, u, 0) catch return ToolError.InternalError;
        if (session.currentFrame()) |f| break :blk f.url;
        return "No current page. Pass `url` to filter by host or `all=true` to list every cookie.";
    };
    const host: ?[]const u8 = if (filter_url) |u| lp.URL.getHostname(u) else null;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const writer = &aw.writer;
    var count: usize = 0;
    var it = jar.iterator();
    while (it.next()) |cookie| {
        if (host) |h| if (!cookie.matchesHost(h)) continue;
        writer.print("{s}={s}", .{ cookie.name, cookie.value }) catch return ToolError.InternalError;
        writer.print("; domain={s}; path={s}", .{ cookie.domain, cookie.path }) catch return ToolError.InternalError;
        if (cookie.secure) writer.writeAll("; Secure") catch return ToolError.InternalError;
        if (cookie.http_only) writer.writeAll("; HttpOnly") catch return ToolError.InternalError;
        writer.writeAll("\n") catch return ToolError.InternalError;
        count += 1;
    }
    if (count == 0) {
        const label = filter_url orelse "(unfiltered)";
        return arena.print("No cookies for {s}.", .{label}) catch ToolError.InternalError;
    }
    return aw.written();
}

fn requireFrame(session: *lp.Session) ToolError!*lp.Frame {
    return session.currentFrame() orelse ToolError.FrameNotLoaded;
}

fn renderJson(arena: std.mem.Allocator, value: anytype, options: std.json.Stringify.Options) ToolError![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, options) catch ToolError.InternalError;
}

fn ensurePage(session: *lp.Session, registry: *NodeRegistry, url: ?[:0]const u8, timeout: ?u32) ToolError!*lp.Frame {
    if (url) |u| {
        if (session.currentFrame()) |frame| {
            const is_loaded = frame._parse_state != .pre and frame._last_navigate_error == null;
            // Reloading would discard what a redirect or in-page navigation did.
            const is_here = std.mem.eql(u8, frame.url, u) or std.mem.eql(u8, frame._requested_url, u);
            if (is_loaded and is_here) {
                return frame;
            }
        }
        _ = try performGoto(session, registry, u, .{ .timeout = timeout });
    }
    return session.currentFrame() orelse ToolError.FrameNotLoaded;
}

/// Navigations wait only for `load` — the fast snapshot. Content rendered by
/// post-load JS (XHR feeds, search results) may still be missing; the model
/// escalates with the `waitForState` tool when a read looks incomplete. `.done`
/// is deliberately avoided as a default: on real sites trackers/timers keep the
/// network from ever fully idling, so it just rides the timeout.
const default_nav_wait: lp.Config.WaitUntil = .load;
const default_nav_timeout_ms: u32 = 10000;

pub const StartedGoto = struct {
    frame_id: u32,
    timeout_ms: u32,
    until: lp.Config.WaitUntil,
};

/// Open a fresh top-level page and start its navigation. The frame is non-null
/// right after createPage but navigate can change/null it, so callers re-fetch.
fn openPage(session: *lp.Session, url: [:0]const u8) ToolError!lp.Session.PageHandle {
    const page = session.createPage() catch return ToolError.NavigationFailed;
    errdefer page.close();
    _ = page.frame().?.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch return ToolError.NavigationFailed;
    return page;
}

/// Start a navigation without waiting for it to load, so the agent script Runtime
/// can drive several gotos concurrently. `receiver_frame_id`, when set, is the
/// page a re-goto on the same `Page` object replaces — only that page is closed,
/// and only its nodes are evicted from the registry; sibling pages' node IDs stay
/// valid.
pub fn startGoto(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    arguments: ?std.json.Value,
    receiver_frame_id: ?u32,
) ToolError!StartedGoto {
    // This path bypasses `call`, so it needs its own `$LP_*` substitution pass.
    const args = try parseArgs(GotoParams, arena, try substituteStringArgs(arena, .goto, arguments));
    if (receiver_frame_id) |fid| {
        if (session.livePage(fid)) |page| {
            registry.resetFrame(arena, &page.frame);
            session.closePage(fid);
        }
    }
    const page = try openPage(session, args.url);
    return .{
        .frame_id = page.frame_id,
        .timeout_ms = args.timeout orelse default_nav_timeout_ms,
        .until = args.waitUntil,
    };
}

const PerformGotoOpts = struct {
    timeout: ?u32 = null,
    wait_until: lp.Config.WaitUntil = default_nav_wait,
};

fn performGoto(session: *lp.Session, registry: *NodeRegistry, url: [:0]const u8, opts: PerformGotoOpts) ToolError!lp.Session.Runner.WaitResult {
    if (session.primaryPage()) |old_page| {
        registry.reset();
        old_page.close();
    }
    const page = try openPage(session, url);

    var runner = session.runner(.{});
    const condition = lp.Session.Runner.WaitCondition{ .frame_id = page.frame_id, .until = opts.wait_until };
    var conditions = [_]lp.Session.Runner.WaitCondition{condition};
    const result = runner.waitResult(opts.timeout orelse default_nav_timeout_ms, &conditions) catch |err| {
        return if (err == error.Cancelled) ToolError.Cancelled else ToolError.NavigationFailed;
    };

    // re-fetch frame, navigate might have changed it.
    const frame = page.frame() orelse return ToolError.NavigationFailed;
    if (frame._last_navigate_error != null) return ToolError.NavigationFailed;
    if (result == .timeout and frame._parse_state == .pre) return ToolError.NavigationTimeout;
    return result;
}

fn resolveNodeAndPage(session: *lp.Session, registry: *NodeRegistry, node_id: NodeRegistry.Id) ToolError!NodeAndPage {
    const page = try requireFrame(session);
    const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
    return .{ .node = node.dom, .page = page, .target = .{ .backend_node_id = node_id } };
}

fn resolveBySelector(session: *lp.Session, selector: []const u8) ToolError!NodeAndPage {
    const page = try requireFrame(session);
    const element = Selector.querySelector(page.document.asNode(), selector, page) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.InternalError,
        else => return ToolError.InvalidParams,
    };
    const node = (element orelse return ToolError.NodeNotFound).asNode();
    return .{ .node = node, .page = page, .target = .{ .selector = selector } };
}

test "call: unknown tool name surfaces in-band" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const r = try call(arena.allocator(), testing.test_session, &registry, "multi_tool_use.parallel", null, .{ .source = .user });
    try std.testing.expect(r.is_error);
    try std.testing.expectEqualStrings("Unknown tool: multi_tool_use.parallel", r.text);
}

test "call: an argument diagnosis is in-band but counts as invalid_params" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const missing = call(arena.allocator(), testing.test_session, &registry, "evaluate", null, .{ .source = .user });
    try std.testing.expectEqualStrings("missing required argument 'script'", (try missing).text);
    try std.testing.expectEqual(.invalid_params, telemetryOutcome(missing));

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"state\":\"idle\"}", .{});
    const bad_enum = call(arena.allocator(), testing.test_session, &registry, "waitForState", args, .{ .source = .user });
    try std.testing.expect((try bad_enum).is_error);
    try std.testing.expectEqual(.invalid_params, telemetryOutcome(bad_enum));
}

test "tree and nodeDetails read the node's own frame" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/semantic_tree_iframe.html", .{});
    defer page.close();
    const child = page.frame().?.child_frames.items[0];

    const html = (child.document.getDocumentElement() orelse unreachable).asNode();
    const input = (try child.document.querySelector(.wrap("input"), child)).?.asNode();
    const html_id = (try registry.register(html)).id;
    const input_id = (try registry.register(input)).id;

    const aa = testing.arena_allocator;
    const tree_args = try std.json.parseFromSliceLeaky(std.json.Value, aa, try aa.print("{{\"backendNodeId\":{d}}}", .{html_id}), .{});
    const tree = try call(aa, page.session, &registry, "tree", tree_args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "child-label") != null);
    try std.testing.expect(std.mem.find(u8, tree.text, "parent-") == null);

    const details_args = try std.json.parseFromSliceLeaky(std.json.Value, aa, try aa.print("{{\"backendNodeId\":{d}}}", .{input_id}), .{});
    const details = try call(aa, page.session, &registry, "nodeDetails", details_args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, details.text, "child-label") != null);
}

test "tree and nodeDetails list iframes with their URL" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/semantic_tree_iframe.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    _ = try call(aa, page.session, &registry, "evaluate", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"script":"document.querySelector('iframe').contentWindow.history.replaceState(null, '', '?moved'); const f = document.createElement('iframe'); f.setAttribute('src', 'semantic_tree_iframe_child.html?scripted'); document.body.appendChild(f)"}
    , .{}), .{ .source = .user });

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Iframe value='http://127.0.0.1:9582/src/browser/tests/cdp/semantic_tree_iframe_child.html?moved'") != null);
    try std.testing.expect(std.mem.find(u8, tree.text, "Iframe value='http://127.0.0.1:9582/src/browser/tests/cdp/semantic_tree_iframe_child.html?scripted'") != null);

    const iframe = (try page.frame().?.document.querySelector(.wrap("iframe"), page.frame().?)).?.asNode();
    const details_args = try std.json.parseFromSliceLeaky(std.json.Value, aa, try aa.print("{{\"backendNodeId\":{d}}}", .{(try registry.register(iframe)).id}), .{});
    const details = try call(aa, page.session, &registry, "nodeDetails", details_args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, details.text, "\"value\":\"http://127.0.0.1:9582/src/browser/tests/cdp/semantic_tree_iframe_child.html?moved\"") != null);
}

test "goto: a navigation stuck waiting for a connection is an error" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const network = &testing.test_app.network;
    var held: std.ArrayList(*@import("../network/http.zig").Connection) = .empty;
    defer held.deinit(std.testing.allocator);
    defer for (held.items) |conn| network.releaseConnection(conn);
    while (network.getConnection()) |conn| try held.append(std.testing.allocator, conn);

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const stuck = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html","timeout":50}
    , .{});
    try std.testing.expectError(error.NavigationTimeout, call(aa, session, &registry, "goto", stuck, .{ .source = .user }));

    for (held.items) |conn| network.releaseConnection(conn);
    held.clearRetainingCapacity();

    // Short timeouts are for the stuck case only: slow builds (tsan) need
    // longer than that to actually load the page.
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html","timeout":5000}
    , .{});
    const r = try call(aa, session, &registry, "goto", args, .{ .source = .user });
    try std.testing.expectEqualStrings("Navigated. HTTP 200 OK.", r.text);
}

test "tools: tree exposes Chrome-matched custom ARIA states" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_aria_states.html", .{});
    defer page.close();

    const result = try call(testing.arena_allocator, page.session, &registry, "tree", null, .{ .source = .user });
    const expected = [_][]const u8{
        "button 'Expanded details' [expanded]",
        "button 'Collapsed details' [collapsed]",
        "button 'Uppercase expanded' [expanded]",
        "button 'Invalid details' [expanded]",
        "button 'Spaced expanded' [expanded]",
        "listitem 'Listitem expanded' [expanded]",
        "checkbox 'Invalid state' [checked]",
        "checkbox 'Empty checked' [unchecked]",
        "checkbox 'Spaced checked' [checked]",
        "option 'Option checked' [checked]",
        "option 'Option mixed' [mixed]",
        "treeitem 'Treeitem checked' [collapsed] [checked]",
        "checkbox 'Padded false' [checked]",
        "button 'Padded collapsed' [expanded]",
        "checkbox 'Uppercase mixed' [mixed]",
        "checkbox 'Absent checked' [unchecked]",
        "switch 'Switch mixed' [unchecked]",
        "menuitemcheckbox 'Menu checkbox mixed' [mixed]",
        "button 'Custom anchor' [expanded]",
        "checkbox 'Checked terms' [checked]",
    };
    for (expected) |fragment| {
        if (std.mem.find(u8, result.text, fragment) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ fragment, result.text });
            return error.MissingExpectedAriaState;
        }
    }

    // Unsupported roles, empty expanded values, and options or tree items
    // without aria-checked must not manufacture state.
    const ignored = [_][]const u8{ "'Generic expanded'", "'Empty expanded'", "'Option absent'", "'Treeitem absent'" };
    for (ignored) |name| {
        var lines = std.mem.splitScalar(u8, result.text, '\n');
        var found = false;
        while (lines.next()) |line| {
            if (std.mem.find(u8, line, name) == null) continue;
            found = true;
            if (std.mem.find(u8, line, " [expanded]") != null) return error.UnexpectedExpanded;
            if (std.mem.find(u8, line, " [checked]") != null) return error.UnexpectedChecked;
            if (std.mem.find(u8, line, " [unchecked]") != null) return error.UnexpectedUnchecked;
        }
        if (!found) return error.IgnoredNodeMissing;
    }
    try std.testing.expect(std.mem.find(u8, result.text, "'Hidden terms'") == null);
}

test "tools: goto flags an error status instead of reporting success" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/status/429"}
    , .{});
    const r = try call(aa, session, &registry, "goto", args, .{ .nav_note = true, .source = .user });
    try std.testing.expectEqualStrings("HTTP 429 Too Many Requests: this is likely an error or rate-limit page, not the requested content.\n\nNavigated. HTTP 429 Too Many Requests.", r.text);
}

test "tools: goto says what a full browser would have shown" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const iframes = session.load_resources.iframe;
    session.load_resources.iframe = false;
    defer session.load_resources.iframe = iframes;
    testing.expectLog(&.{ .disabled, .page_error });

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/src/browser/tests/cdp/page_status.html"}
    , .{});
    const r = try call(aa, session, &registry, "goto", args, .{ .nav_note = true, .source = .user });
    try std.testing.expectEqualStrings("The page asked for WebGL, which Lightpanda does not provide: anything it renders that way is missing. 1 iframe(s) were not loaded: subframe loading is off.\n\nNavigated. HTTP 200 OK.", r.text);
}

test "tools: a read tool navigating by url flags an error status" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/status/404"}
    , .{});
    const r = try call(aa, session, &registry, "markdown", args, .{ .nav_note = true, .source = .user });
    try std.testing.expect(std.mem.startsWith(u8, r.text, "HTTP 404 Not Found: this is likely an error"));

    const reload = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/status/403"}
    , .{});
    const s = try call(aa, session, &registry, "markdown", reload, .{ .source = .user });
    try std.testing.expect(std.mem.indexOf(u8, s.text, "rate-limit") == null);
}

test "tools: a read tool keeps a page that moved within the document" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    _ = try call(aa, session, &registry, "goto", try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"url\":\"" ++ url ++ "\"}", .{}), .{ .source = .user });
    _ = try call(aa, session, &registry, "evaluate", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"script":"document.body.dataset.mark = 'kept'; history.pushState(null, '', '?moved')"}
    , .{}), .{ .source = .user });

    const r = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"url\":\"" ++ url ++ "\"}", .{}), .{ .nav_note = true, .source = .user });
    try std.testing.expect(std.mem.startsWith(u8, r.text, "The page is at " ++ url ++ "?moved, not " ++ url ++ ":"));
    try std.testing.expect(!r.navigated);

    const empty = try call(aa, session, &registry, "tree", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":""}
    , .{}), .{ .nav_note = true, .source = .user });
    try std.testing.expect(!empty.is_error and !empty.navigated);

    const mark = try call(aa, session, &registry, "evaluate", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"script":"document.body.dataset.mark"}
    , .{}), .{ .source = .user });
    try std.testing.expectEqualStrings("kept", mark.text);
}

test "tools: a read tool keeps a page reached through a redirect" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/xhr/redirect"}
    , .{});
    _ = try call(aa, session, &registry, "goto", args, .{ .source = .user });
    _ = try call(aa, session, &registry, "evaluate", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"script":"document.body.dataset.mark = 'kept'"}
    , .{}), .{ .source = .user });

    _ = try call(aa, session, &registry, "markdown", args, .{ .source = .user });
    const mark = try call(aa, session, &registry, "evaluate", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"script":"document.body.dataset.mark"}
    , .{}), .{ .source = .user });
    try std.testing.expectEqualStrings("kept", mark.text);
}

test "tools: a bot challenge is named" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:9582/challenge/vercel"}
    , .{});
    const r = try call(aa, session, &registry, "tree", args, .{ .nav_note = true, .source = .user });
    try std.testing.expect(std.mem.startsWith(u8, r.text, "Blocked by a vercel bot challenge (HTTP 429 Too Many Requests)"));
}

test "tools: navStatus names the status, or says it has none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // No response yet.
    try std.testing.expectEqualStrings("unknown", navStatus(aa, frame));

    frame._http_status = 403;
    try std.testing.expectEqualStrings("403 Forbidden", navStatus(aa, frame));
    frame._http_status = 404;
    try std.testing.expectEqualStrings("404 Not Found", navStatus(aa, frame));

    // A code std has no phrase for still reports the number.
    frame._http_status = 599;
    try std.testing.expectEqualStrings("599", navStatus(aa, frame));

    // Out of range for std.http.Status, which is an enum(u10).
    frame._http_status = 9999;
    try std.testing.expectEqualStrings("9999", navStatus(aa, frame));
}

test "execGetEnv reads LP_* values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const var_name = "LP_GETENV_TEST_OK";
    const var_value = "hello-world";
    _ = testing.setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = testing.unsetenv(@constCast(var_name));

    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, "name", .{ .string = var_name });
    const arguments: std.json.Value = .{ .object = obj };

    const r = try execGetEnv(aa, arguments);
    try std.testing.expectEqualStrings(var_value, r);
}

test "execGetEnv hides non-LP_ values even when set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const var_name = "LIGHTPANDA_GETENV_TEST_OUTSIDE";
    const var_value = "should-not-leak";
    _ = testing.setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = testing.unsetenv(@constCast(var_name));

    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, "name", .{ .string = var_name });
    const arguments: std.json.Value = .{ .object = obj };

    const r = try execGetEnv(aa, arguments);
    try std.testing.expect(std.mem.find(u8, r, var_value) == null);
    try std.testing.expectEqualStrings(
        "Environment variable '" ++ var_name ++ "' is not set",
        r,
    );
}

test "formatLpEnvNames renders names without values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env_names = [_][]const u8{ "LP_BAR", "LP_FOO" };
    const r = try formatLpEnvNames(aa, &env_names);

    try std.testing.expect(std.mem.find(u8, r, "LP_FOO") != null);
    try std.testing.expect(std.mem.find(u8, r, "LP_BAR") != null);
    try std.testing.expect(std.mem.find(u8, r, "secret") == null);
}

test "formatLpEnvNames reports empty when no names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const r = try formatLpEnvNames(aa, &.{});
    try std.testing.expectEqualStrings("No LP_* environment variables are set.", r);
}

test "isPathSafe: relative paths without traversal are accepted" {
    try std.testing.expect(isPathSafe("foo.txt"));
    try std.testing.expect(isPathSafe("./foo.txt"));
    try std.testing.expect(isPathSafe("sub/foo.txt"));
    try std.testing.expect(isPathSafe("a/b/c/d.png"));
    try std.testing.expect(isPathSafe("dir/file.with..dots"));
}

test "isPathSafe: absolute paths and traversal are rejected" {
    try std.testing.expect(!isPathSafe(""));
    try std.testing.expect(!isPathSafe("/etc/passwd"));
    try std.testing.expect(!isPathSafe("/foo"));
    try std.testing.expect(!isPathSafe("../etc/passwd"));
    try std.testing.expect(!isPathSafe("..\\windows\\system32"));
    try std.testing.expect(!isPathSafe("sub/../etc/passwd"));
    try std.testing.expect(!isPathSafe("sub/.."));
    try std.testing.expect(!isPathSafe(".."));
}

test "markdown: alternate reads the page's text/markdown link" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const base = "http://localhost:9582/src/browser/tests/";
    const source = @embedFile("tests/markdown_source.md");

    const page = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"url\":\"" ++ base ++ "markdown_alternate.html\"}", .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, page.text, "Rendered page") != null);

    const followed = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"alternate":true}
    , .{}), .{ .source = .user });
    try std.testing.expectEqualStrings("<!-- markdown alternate: " ++ base ++ "markdown_source.md -->\n" ++ source, followed.text);
    // Read in a page of its own: the current page stays put.
    try std.testing.expect(!followed.navigated);
    try std.testing.expectEqual(1, session.pages.items.len);
    try std.testing.expectEqualStrings(base ++ "markdown_alternate.html", session.currentFrame().?.url);

    const capped = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"alternate":true,"maxBytes":7}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, capped.text, "-->\n# Title\n\n[truncated]") != null);

    // The alternate stands for the whole page: no scoping, as in `fetch`.
    try std.testing.expectError(ToolError.InvalidParams, call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"alternate":true,"selector":"p"}
    , .{}), .{ .source = .user }));

    // Many servers send .md files as text/plain; followed, it is written as-is.
    const plain = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"alternate\":true,\"url\":\"" ++ base ++ "markdown_alternate_plain.html\"}", .{}), .{ .source = .user });
    try std.testing.expectEqualStrings("<!-- markdown alternate: " ++ base ++ "markdown_source.txt -->\n" ++ source, plain.text);

    // An alternate that doesn't load as markdown falls back to the page.
    const fallback = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"alternate\":true,\"url\":\"" ++ base ++ "markdown_alternate_html.html\"}", .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, fallback.text, "Alternate is HTML") != null);
    try std.testing.expectEqual(1, session.pages.items.len);

    // A page that failed keeps its own content: the alternate's 200 would hide it.
    _ = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"url\":\"" ++ base ++ "markdown_alternate.html\"}", .{}), .{ .source = .user });
    session.currentFrame().?._http_status = 404;
    const failed = try call(aa, session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"alternate":true}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, failed.text, "Rendered page") != null);
    try std.testing.expect(std.mem.find(u8, failed.text, "markdown alternate") == null);
}

test "startGoto: a navigation that fails to start leaves no page behind" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    const pages = session.pages.items.len;

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"blob:http://localhost:9582/missing"}
    , .{});
    try std.testing.expectError(ToolError.NavigationFailed, startGoto(aa, session, &registry, args, null));
    try std.testing.expectEqual(pages, session.pages.items.len);
}

test "markdown: a same-url page whose navigation failed is navigated again" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    const session = testing.test_session;
    defer if (session.primaryPage()) |page| page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"url":"http://localhost:1/"}
    , .{});
    try std.testing.expect((try call(aa, session, &registry, "goto", args, .{ .source = .user })).is_error);
    try std.testing.expect((try call(aa, session, &registry, "markdown", args, .{ .source = .user })).is_error);
}

test "acceptCookies: a page with nothing to click costs no model call" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("markdown_alternate_plain.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    // No TYPESAFE_API_KEY is set in the test environment, so reaching the
    // model at all would have said so here.
    try std.testing.expect(std.mem.find(u8, result.text, "could be clicked") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":false") != null);
}

test "acceptCookies: the recorded control is clicked without the model" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#accept"}
    , .{});
    const result = try call(aa, page.session, &registry, "acceptCookies", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "without asking the model") != null);
    // A replay repeats a decision, it does not check it.
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":false") != null);
    // What `--save` writes into the script, so the next run clicks it directly.
    try std.testing.expectEqualStrings("{\"selector\":\"#accept\"}", result.replay_args.?);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Accept all cookies") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "Headline") != null);
}

test "login: the recorded selectors are filled and submitted without the model" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","usernameSelector":"#user","passwordSelector":"#pass","submitSelector":"#submit"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "without asking the model") != null);
    try std.testing.expectEqualStrings(
        "{\"usernameSelector\":\"#user\",\"passwordSelector\":\"#pass\",\"submitSelector\":\"#submit\"}",
        result.replay_args.?,
    );

    const status = try call(aa, page.session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#status"}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, status.text, "submitted") != null);

    // The identifier is on the page, the password is masked everywhere the
    // state is built — including the request a verification would send.
    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "ada") != null);
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "*****") != null);
}

test "acceptCookies: the control Jev picks is clicked and the re-read verifies it" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.start(aa);
    defer jev.stop();

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "Accept all cookies") != null);
    // The answer is recorded as a selector, so a replay asks nothing.
    try std.testing.expect(result.replay_args != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Accept all cookies") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "Headline") != null);
}

test "login: Jev picks the identifier, the password field and the submit control" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.start(aa);
    defer jev.stop();

    // decideOnly, so nothing is typed and the decoy newsletter form is the
    // only thing that could have been picked by mistake.
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","decideOnly":true}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"usernameSelector\":\"#user\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"passwordSelector\":\"#pass\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitSelector\":\"#submit\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") == null);
}

/// The counter `ticking.html` advances from a 20ms interval.
fn tickCount(aa: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry) !u32 {
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#ticks"}
    , .{});
    const result = try call(aa, session, registry, "markdown", args, .{ .source = .user });
    return std.fmt.parseInt(u32, std.mem.trim(u8, result.text, &std.ascii.whitespace), 10);
}

test "classify: the page is still serviced while the model is asked" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("ticking.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.startSlow(aa);
    defer jev.stop();

    const before = try tickCount(aa, page.session, &registry);
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"questions":{"isBlocked":true}}
    , .{});
    const result = try call(aa, page.session, &registry, "classify", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);

    // Pumping gives the page a turn per quiet slice (250ms, see
    // `Session.idleSlice`), so a 400ms answer buys it about two. Asking on
    // this thread instead buys it none at all, whatever the interval.
    const after = try tickCount(aa, page.session, &registry);
    try std.testing.expect(after > before);
}

test "classify: a page that navigates while the model is asked is not answered for" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("late_redirect.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.startSlow(aa);
    defer jev.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"questions":{"isBlocked":true}}
    , .{});
    const result = try call(aa, page.session, &registry, "classify", args, .{ .source = .user });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "navigated while the model was asked") != null);

    const url = try call(aa, page.session, &registry, "getUrl", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, url.text, "consent_banner.html") != null);
}

test "acceptCookies: a click that moves the page stops the second guess" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner_navigates.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.start(aa);
    defer jev.stop();

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    // #reject exists on the page the accept link went to, so the runner-up
    // would have resolved there and clicked a control nobody chose.
    try std.testing.expect(std.mem.find(u8, result.text, "\"attempts\":1") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":false") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "the click moved the page") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Reject non-essential") != null);
}

test "login: the password waits for the step that asks for it" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_two_step.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.start(aa);
    defer jev.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"loggedIn\":true") != null);
    // A decision per step, and the verification after them.
    try std.testing.expect(std.mem.find(u8, result.text, "\"calls\":3") != null);
    try std.testing.expectEqualStrings(
        "{\"usernameSelector\":\"#user\",\"passwordSelector\":\"#pass\",\"submitSelector\":\"#signin-submit\"}",
        result.replay_args.?,
    );

    const status = try call(aa, page.session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#status"}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, status.text, "submitted") != null);
}

test "login: a later step that asks for the password in the clear is refused" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_two_step_cleartext.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.start(aa);
    defer jev.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, result.text, "input[type=password]") != null);
    // The identifier did go, and the verdict says so.
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"loggedIn\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
}

test "login: a recorded two-step login submits the identifier before the password" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_two_step.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","usernameSelector":"#user","passwordSelector":"#pass","submitSelector":"#signin-submit"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "without asking the model") != null);
    // The recorded control belongs to the second step, so the first one is
    // submitted with Enter in the field we just filled.
    try std.testing.expect(std.mem.find(u8, result.text, "\"pressedEnter\":true") != null);

    const status = try call(aa, page.session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#status"}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, status.text, "submitted") != null);
}

test "login: a verification that fails still reports that credentials went out" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const jev = try testing.MockJev.startFailingVerification(aa);
    defer jev.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "could not check whether the sign-in worked") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "HTTP 500") != null);
    // What we did, not only what broke.
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(result.replay_args != null);
}

test "acceptCookies: a missing key is reported so the REPL can ask a model instead" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    _ = testing.unsetenv(@constCast(zenai.typesafe.env_var_name));

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(result.is_error);
    // What `/acceptCookies` reads to fall back to the prompt it used to send.
    try std.testing.expectEqual(.missing_api_key, result.failure);
    try std.testing.expect(std.mem.find(u8, result.text, zenai.typesafe.env_var_name) != null);
}

test "login: a passwordSelector that is not a password field is refused" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"password":"hunter2","passwordSelector":"#user"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, result.text, "input[type=password]") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
}

test "fill: a password is not typed into a form an https page posts in the clear" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_plaintext.html", .{});
    defer page.close();
    // Served over http here, so the downgrade only exists once the page claims
    // to be secure.
    page.frame().?.url = "https://example.com/account";

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#pass","value":"hunter2"}
    , .{});
    const refused = try call(aa, page.session, &registry, "fill", args, .{ .source = .user });
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.find(u8, refused.text, "plaintext http://") != null);

    // The identifier is not a credential the scheme can leak, so it still fills.
    const allowed = try call(aa, page.session, &registry, "fill", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#user","value":"ada"}
    , .{}), .{ .source = .user });
    try std.testing.expect(!allowed.is_error);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "ada") != null);
}

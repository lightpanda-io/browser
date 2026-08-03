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

//! C ABI for embedding Lightpanda as a library. The contract lives in
//! include/lightpanda.h; this file must stay in sync with it.
//!
//! Threading contract (v1): `lp_init` may be called once per process (V8's
//! platform cannot be re-initialized after `lp_shutdown`), and every call on
//! the resulting handle — including all its sessions — must come from the
//! thread that called `lp_init`. V8 isolates have thread affinity; sessions
//! park their isolate between calls so many can share that one thread, the
//! same discipline as `mcp.HttpServer`.

const std = @import("std");
const lp = @import("lightpanda");

const c_allocator = std.heap.c_allocator;

// Cap on arena capacity kept across result-arena resets: recycle small
// results, return multi-MB page dumps to the OS.
const result_retain_limit = 256 * 1024;

// Values mirrored in include/lightpanda.h (lp_status).
const Status = enum(c_int) {
    ok = 0,
    invalid_params = 1,
    frame_not_loaded = 2,
    node_not_found = 3,
    navigation_failed = 4,
    cancelled = 5,
    timeout = 6,
    out_of_memory = 7,
    internal = 8,
    // API misuse: double init, init after shutdown, null handle.
    misuse = 9,
};

// Mirrored in include/lightpanda.h (lp_result), which documents the
// result lifetime and string contract.
const Result = extern struct {
    text: ?[*]const u8,
    len: usize,
    is_error: bool,

    const empty: Result = .{ .text = null, .len = 0, .is_error = false };
};

// Mirrored in include/lightpanda.h (lp_options), which documents the
// sentinel values. Zero-initialized means defaults everywhere.
const InitOpts = extern struct {
    user_agent: ?[*]const u8,
    user_agent_len: usize,
    http_proxy: ?[*]const u8,
    http_proxy_len: usize,
    http_cache_dir: ?[*]const u8,
    http_cache_dir_len: usize,
    http_timeout_ms: u32,
    watchdog_ms: i32,
};

// Mirrored in include/lightpanda.h (lp_fetch_opts). Formats and wait
// conditions travel as plain ints so out-of-range values from C are
// rejected instead of being illegal to load.
const FetchOpts = extern struct {
    format: c_int,
    wait_ms: u32,
    wait_until: c_int,
    wait_selector: ?[*]const u8,
    wait_selector_len: usize,
};

// Mirrored in include/lightpanda.h (lp_format).
const Format = enum(c_int) {
    html = 0,
    markdown = 1,
    tree_json = 2,
    tree_text = 3,
};

// Mirrored in include/lightpanda.h (lp_wait_until).
const WaitUntil = enum(c_int) {
    default = 0,
    load = 1,
    domcontentloaded = 2,
    networkalmostidle = 3,
    networkidle = 4,
    done = 5,
};

const BrowserHandle = struct {
    config: lp.Config,
    app: *lp.App,
    // Owns the option strings duped out of the caller's InitOpts.
    config_arena: std.heap.ArenaAllocator,
    // Owns the previous lp_fetch result; reset at the start of the next one.
    fetch_arena: std.heap.ArenaAllocator,
    // lp_fetch's browser, created on first use and reused after — each call
    // still gets a fresh session. Its isolate parks between calls.
    fetch_browser: ?lp.Browser,
    sessions: std.ArrayList(*SessionHandle),
    // Static @errorName of the last failing lp_fetch/lp_session_new.
    last_error: []const u8,
};

const Cancel = struct {
    cb: *const fn (?*anyopaque) callconv(.c) bool,
    ctx: ?*anyopaque,
};

const SessionHandle = struct {
    owner: *BrowserHandle,
    ts: lp.ToolSession,
    // Per-call scratch and the returned result; the reset at the start of
    // the next lp_call is the header's documented result lifetime.
    arena: std.heap.ArenaAllocator,
    cancel: ?Cancel,
    // Static @errorName of the last failing lp_call.
    last_error: []const u8,
};

// V8's platform is process-global and cannot be re-initialized after
// dispose, so init is once-and-final: live never coexists with a second
// handle, and shutdown is terminal.
const AppState = enum { uninitialized, live, shutdown };
var app_state: AppState = .uninitialized;

/// Initialize the library and return the process-wide browser handle.
/// Callable exactly once per process; after `lp_shutdown` it fails with
/// `misuse` forever (V8 cannot be re-initialized).
pub export fn lp_init(opts_: ?*const InitOpts, out_: ?**BrowserHandle) Status {
    const out = out_ orelse return .misuse;
    if (app_state != .uninitialized) return .misuse;

    const handle = createBrowser(opts_) catch |err| return errStatus(err);
    app_state = .live;
    out.* = handle;
    return .ok;
}

fn createBrowser(opts_: ?*const InitOpts) !*BrowserHandle {
    const handle = try c_allocator.create(BrowserHandle);
    errdefer c_allocator.destroy(handle);

    handle.config_arena = .init(c_allocator);
    errdefer handle.config_arena.deinit();
    handle.fetch_arena = .init(c_allocator);
    errdefer handle.fetch_arena.deinit();
    const arena = handle.config_arena.allocator();

    var mode: @FieldType(lp.Config.Mode, "embed") = .{};
    if (opts_) |opts| {
        if (opts.user_agent) |ua| {
            const span = ua[0..opts.user_agent_len];
            lp.Config.validateUserAgent(span) catch return error.InvalidParams;
            mode.user_agent = try arena.dupe(u8, span);
        }
        if (opts.http_proxy) |proxy| {
            mode.http_proxy = try arena.dupeZ(u8, proxy[0..opts.http_proxy_len]);
        }
        if (opts.http_cache_dir) |dir| {
            mode.http_cache_dir = try arena.dupe(u8, dir[0..opts.http_cache_dir_len]);
        }
        if (opts.http_timeout_ms != 0) {
            mode.http_timeout = std.math.cast(u31, opts.http_timeout_ms) orelse return error.InvalidParams;
        }
        // Config.watchdogMs treats 0 as "no watchdog" and null as the default.
        if (opts.watchdog_ms < 0) {
            mode.watchdog_ms = 0;
        } else if (opts.watchdog_ms > 0) {
            mode.watchdog_ms = @intCast(opts.watchdog_ms);
        }
    }

    handle.config = try lp.Config.init(c_allocator, "lightpanda", .{ .embed = mode });
    errdefer handle.config.deinit(c_allocator);

    // Everything above is plain validation and can be retried; App.init
    // touches V8's process-global platform, so a failure here poisons the
    // process like a shutdown does.
    handle.app = lp.App.init(c_allocator, &handle.config) catch |err| {
        app_state = .shutdown;
        return err;
    };
    handle.fetch_browser = null;
    handle.sessions = .empty;
    handle.last_error = "";
    return handle;
}

/// Tear down every remaining session and the process-wide state. Terminal:
/// the library cannot be initialized again in this process.
pub export fn lp_shutdown(handle_: ?*BrowserHandle) void {
    const handle = handle_ orelse return;
    if (app_state != .live) return;

    while (handle.sessions.pop()) |session| destroySession(session);
    handle.sessions.deinit(c_allocator);
    if (handle.fetch_browser) |*browser| {
        // Browser.deinit's Env.deinit exit balances against this enter.
        browser.env.isolate.enter();
        browser.deinit();
    }
    handle.app.deinit();
    handle.config.deinit(c_allocator);
    handle.fetch_arena.deinit();
    handle.config_arena.deinit();
    c_allocator.destroy(handle);
    app_state = .shutdown;
}

/// Load `url` in a throwaway session and return the page serialized per
/// `opts` (default: HTML after the page settles). NULL `opts` means all
/// defaults. `out` stays valid until the next `lp_fetch` on this handle or
/// `lp_shutdown`.
pub export fn lp_fetch(
    handle_: ?*BrowserHandle,
    url_: ?[*]const u8,
    url_len: usize,
    opts_: ?*const FetchOpts,
    out_: ?*Result,
) Status {
    const handle = handle_ orelse return .misuse;
    const out = out_ orelse return .misuse;
    out.* = .empty;
    if (app_state != .live) return .misuse;
    const url_ptr = url_ orelse return .invalid_params;
    if (url_len == 0) return .invalid_params;

    // At the start, not on the way out: the previous result must stay valid
    // until this call begins. The reset precedes the option parsing because
    // the input strings are duped into this arena.
    _ = handle.fetch_arena.reset(.{ .retain_with_limit = result_retain_limit });
    handle.last_error = "";
    const arena = handle.fetch_arena.allocator();
    const url = arena.dupeZ(u8, url_ptr[0..url_len]) catch return .out_of_memory;

    var fetch_opts: lp.FetchOpts = .{ .dump = .{}, .dump_mode = .html };
    if (opts_) |opts| {
        const format = std.enums.fromInt(Format, opts.format) orelse return .invalid_params;
        fetch_opts.dump_mode = switch (format) {
            .html => .html,
            .markdown => .markdown,
            .tree_json => .semantic_tree,
            .tree_text => .semantic_tree_text,
        };
        if (opts.wait_ms != 0) fetch_opts.wait_ms = opts.wait_ms;
        const wait_until = std.enums.fromInt(WaitUntil, opts.wait_until) orelse return .invalid_params;
        fetch_opts.wait_until = switch (wait_until) {
            .default => null,
            .load => .load,
            .domcontentloaded => .domcontentloaded,
            .networkalmostidle => .networkalmostidle,
            .networkidle => .networkidle,
            .done => .done,
        };
        if (opts.wait_selector) |selector| {
            fetch_opts.wait_selector = arena.dupeZ(u8, selector[0..opts.wait_selector_len]) catch return .out_of_memory;
        }
    }

    var writer: std.Io.Writer.Allocating = .init(arena);
    fetch_opts.writer = &writer.writer;

    // Sessions park their isolate between calls, so entering this
    // browser's isolate here nests correctly. Browser.init leaves the
    // isolate entered; the exit below parks it either way.
    if (handle.fetch_browser) |*browser| {
        browser.env.isolate.enter();
    } else {
        handle.fetch_browser = @as(lp.Browser, undefined);
        (&handle.fetch_browser.?).init(handle.app, .{}, null) catch |err| {
            handle.fetch_browser = null;
            handle.last_error = @errorName(err);
            return .internal;
        };
    }
    const browser = &handle.fetch_browser.?;
    defer browser.env.isolate.exit();

    lp.fetch(handle.app, browser, &.{url}, fetch_opts) catch |err| {
        handle.last_error = @errorName(err);
        return errStatus(err);
    };

    const text = writer.written();
    out.* = .{ .text = text.ptr, .len = text.len, .is_error = false };
    return .ok;
}

/// Create an isolated browsing session (its own V8 isolate, page, cookies
/// and memory). Close with `lp_session_close`; any session still open at
/// `lp_shutdown` is closed then.
pub export fn lp_session_new(handle_: ?*BrowserHandle, out_: ?**SessionHandle) Status {
    const handle = handle_ orelse return .misuse;
    const out = out_ orelse return .misuse;
    if (app_state != .live) return .misuse;

    out.* = createSession(handle) catch |err| {
        handle.last_error = @errorName(err);
        return errStatus(err);
    };
    handle.last_error = "";
    return .ok;
}

/// Exhaustive so a new ToolError tag forces a mapping decision at
/// compile time.
fn toolStatus(err: lp.tools.ToolError) Status {
    return switch (err) {
        error.FrameNotLoaded => .frame_not_loaded,
        error.InvalidParams => .invalid_params,
        error.NodeNotFound => .node_not_found,
        error.NavigationFailed => .navigation_failed,
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.InternalError => .internal,
        error.OutOfMemory => .out_of_memory,
    };
}

/// For the anyerror paths (init, fetch): tool errors keep their toolStatus
/// mapping, anything else is internal.
fn errStatus(err: anyerror) Status {
    inline for (@typeInfo(lp.tools.ToolError).error_set.?) |e| {
        const tool_err = @field(lp.tools.ToolError, e.name);
        if (err == tool_err) return toolStatus(tool_err);
    }
    return .internal;
}

fn createSession(handle: *BrowserHandle) !*SessionHandle {
    const entry = try c_allocator.create(SessionHandle);
    errdefer c_allocator.destroy(entry);

    entry.owner = handle;
    entry.cancel = null;
    entry.last_error = "";
    entry.arena = .init(c_allocator);
    errdefer entry.arena.deinit();

    try entry.ts.init(handle.app);
    errdefer entry.ts.deinit();

    entry.ts.setCancelHook(.{ .context = entry, .check = cancelTrampoline });

    try handle.sessions.append(c_allocator, entry);

    // ToolSession.init left the isolate entered; park it so sessions can
    // share the thread.
    entry.ts.exitIsolate();
    return entry;
}

/// Close a session created by `lp_session_new`, freeing its isolate, page
/// and memory. The handle is invalid afterwards.
pub export fn lp_session_close(entry_: ?*SessionHandle) void {
    const entry = entry_ orelse return;
    // After lp_shutdown every session is already destroyed; a stale handle
    // must be inert, not a use-after-free.
    if (app_state != .live) return;
    const sessions = &entry.owner.sessions;
    for (sessions.items, 0..) |session, i| {
        if (session == entry) {
            _ = sessions.swapRemove(i);
            break;
        }
    }
    destroySession(entry);
}

fn destroySession(entry: *SessionHandle) void {
    entry.ts.enterIsolate();
    entry.ts.deinit();
    entry.arena.deinit();
    c_allocator.destroy(entry);
}

/// Run one browser tool against the session. `tool` is a name from
/// `lp_tools_json` (goto, markdown, extract, click, …); `args_json` is that
/// tool's argument object as a JSON string, or NULL for no arguments. On
/// `LP_OK`, `out` stays valid until the next `lp_call` on this session or
/// `lp_session_close`; `out->is_error` signals an in-band page-level
/// failure (e.g. a JS throw inside evaluate/extract) whose message is in
/// `out->text`.
pub export fn lp_call(
    entry_: ?*SessionHandle,
    tool_: ?[*]const u8,
    tool_len: usize,
    args_json_: ?[*]const u8,
    args_json_len: usize,
    out_: ?*Result,
) Status {
    const entry = entry_ orelse return .misuse;
    const out = out_ orelse return .misuse;
    out.* = .empty;
    if (app_state != .live) return .misuse;
    const tool = tool_ orelse return .invalid_params;

    // At the start, not on the way out: the previous result must stay
    // valid until this call begins.
    _ = entry.arena.reset(.{ .retain_with_limit = result_retain_limit });
    entry.last_error = "";
    const arena = entry.arena.allocator();

    var args: ?std.json.Value = null;
    if (args_json_) |args_json| {
        args = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json[0..args_json_len], .{}) catch |err| {
            entry.last_error = @errorName(err);
            return .invalid_params;
        };
    }

    entry.ts.enterIsolate();
    defer entry.ts.exitIsolate();

    const result = lp.tools.call(arena, entry.ts.session, &entry.ts.registry, tool[0..tool_len], args) catch |err| {
        entry.last_error = @errorName(err);
        return toolStatus(err);
    };

    out.* = .{ .text = result.text.ptr, .len = result.text.len, .is_error = result.is_error };
    return .ok;
}

/// Pump the session's background work (timers, in-flight fetches, resumed
/// JS) once. Returns the number of milliseconds the caller may sleep before
/// pumping again. Only needed when idling between calls; every tool call
/// already waits for its own completion.
pub export fn lp_session_pump(entry_: ?*SessionHandle) u32 {
    const entry = entry_ orelse return 0;
    if (app_state != .live) return 0;
    entry.ts.enterIsolate();
    defer entry.ts.exitIsolate();
    return entry.ts.session.idleSlice();
}

/// Install (or clear, with NULL `cb`) a cancellation probe polled during
/// blocking waits: once it returns true, the in-flight call fails with
/// `LP_ERR_CANCELLED`. The probe is invoked on the session's thread, but it
/// may read state set by another thread (e.g. an atomic flag flipped by a
/// signal handler).
pub export fn lp_session_set_cancel_hook(
    entry_: ?*SessionHandle,
    cb: ?*const fn (?*anyopaque) callconv(.c) bool,
    ctx: ?*anyopaque,
) void {
    const entry = entry_ orelse return;
    if (app_state != .live) return;
    entry.cancel = if (cb) |f| .{ .cb = f, .ctx = ctx } else null;
}

fn cancelTrampoline(ctx: *anyopaque) bool {
    const entry: *SessionHandle = @ptrCast(@alignCast(ctx));
    const cancel = entry.cancel orelse return false;
    return cancel.cb(cancel.ctx);
}

/// Error name of the most recent failing `lp_call` on this session; empty
/// when the last call succeeded. Static storage — do not free.
pub export fn lp_last_error(entry_: ?*SessionHandle, len_: ?*usize) ?[*]const u8 {
    if (len_) |len| len.* = 0;
    const entry = entry_ orelse return null;
    if (app_state != .live) return null;
    if (len_) |len| len.* = entry.last_error.len;
    return entry.last_error.ptr;
}

/// Like `lp_last_error`, for the browser-level calls (`lp_fetch`,
/// `lp_session_new`).
pub export fn lp_browser_last_error(handle_: ?*BrowserHandle, len_: ?*usize) ?[*]const u8 {
    if (len_) |len| len.* = 0;
    const handle = handle_ orelse return null;
    if (app_state != .live) return null;
    if (len_) |len| len.* = handle.last_error.len;
    return handle.last_error.ptr;
}

/// JSON array describing every tool `lp_call` accepts, in the MCP
/// tools/list wire shape: [{"name", "description", "inputSchema"}, …].
/// Static storage — do not free.
pub export fn lp_tools_json() [*:0]const u8 {
    tools_json_once.call();
    return tools_json.ptr;
}

var tools_json: [:0]const u8 = undefined;
var tools_json_once = lp.once(buildToolsJson);

fn buildToolsJson() void {
    var writer: std.Io.Writer.Allocating = .init(c_allocator);
    defer writer.deinit();
    writeToolsJson(&writer.writer) catch @panic("OOM");
    tools_json = writer.toOwnedSliceSentinel(0) catch @panic("OOM");
}

// Rendered from the protocol-neutral lp.tools.tool_defs: the shape is this
// ABI's contract (see the header), independent of how the MCP adapter
// evolves its own tools/list wire type.
fn writeToolsJson(w: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginArray();
    for (lp.tools.names, lp.tools.tool_defs) |name, def| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(name);
        try jw.objectField("description");
        try jw.write(def.description);
        try jw.objectField("inputSchema");
        _ = try jw.beginWriteRaw();
        try jw.writer.writeAll(def.input_schema);
        jw.endWriteRaw();
        try jw.endObject();
    }
    try jw.endArray();
}

/// The library version. Static storage — do not free.
pub export fn lp_version() [*:0]const u8 {
    return version.ptr;
}

const version: [:0]const u8 = lp.build_config.version ++ "";

const testing = std.testing;

test "c_api: mirrors the header ABI" {
    const h = @import("lightpanda_h");

    try testing.expectEqual(h.LP_OK, @intFromEnum(Status.ok));
    try testing.expectEqual(h.LP_ERR_INVALID_PARAMS, @intFromEnum(Status.invalid_params));
    try testing.expectEqual(h.LP_ERR_FRAME_NOT_LOADED, @intFromEnum(Status.frame_not_loaded));
    try testing.expectEqual(h.LP_ERR_NODE_NOT_FOUND, @intFromEnum(Status.node_not_found));
    try testing.expectEqual(h.LP_ERR_NAVIGATION_FAILED, @intFromEnum(Status.navigation_failed));
    try testing.expectEqual(h.LP_ERR_CANCELLED, @intFromEnum(Status.cancelled));
    try testing.expectEqual(h.LP_ERR_TIMEOUT, @intFromEnum(Status.timeout));
    try testing.expectEqual(h.LP_ERR_OUT_OF_MEMORY, @intFromEnum(Status.out_of_memory));
    try testing.expectEqual(h.LP_ERR_INTERNAL, @intFromEnum(Status.internal));
    try testing.expectEqual(h.LP_ERR_MISUSE, @intFromEnum(Status.misuse));

    try testing.expectEqual(h.LP_FORMAT_HTML, @intFromEnum(Format.html));
    try testing.expectEqual(h.LP_FORMAT_MARKDOWN, @intFromEnum(Format.markdown));
    try testing.expectEqual(h.LP_FORMAT_TREE_JSON, @intFromEnum(Format.tree_json));
    try testing.expectEqual(h.LP_FORMAT_TREE_TEXT, @intFromEnum(Format.tree_text));

    try testing.expectEqual(h.LP_WAIT_DEFAULT, @intFromEnum(WaitUntil.default));
    try testing.expectEqual(h.LP_WAIT_LOAD, @intFromEnum(WaitUntil.load));
    try testing.expectEqual(h.LP_WAIT_DOMCONTENTLOADED, @intFromEnum(WaitUntil.domcontentloaded));
    try testing.expectEqual(h.LP_WAIT_NETWORKALMOSTIDLE, @intFromEnum(WaitUntil.networkalmostidle));
    try testing.expectEqual(h.LP_WAIT_NETWORKIDLE, @intFromEnum(WaitUntil.networkidle));
    try testing.expectEqual(h.LP_WAIT_DONE, @intFromEnum(WaitUntil.done));

    try expectSameLayout(h.lp_result, Result);
    try expectSameLayout(h.lp_options, InitOpts);
    try expectSameLayout(h.lp_fetch_opts, FetchOpts);

    // The exports are pub so this reflection sees them; a header prototype
    // must exist (compile error otherwise) and agree on arity and sizes.
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "lp_")) {
            try expectSameSignature(@TypeOf(@field(h, decl.name)), @TypeOf(@field(@This(), decl.name)));
        }
    }

    // The lines above only prove the Zig side exists in the header; the
    // counts catch a constant or function added to the header alone.
    try testing.expectEqual(@typeInfo(Format).@"enum".fields.len, comptime countPrefixed(h, "LP_FORMAT_"));
    try testing.expectEqual(@typeInfo(WaitUntil).@"enum".fields.len, comptime countPrefixed(h, "LP_WAIT_"));
    try testing.expectEqual(@typeInfo(Status).@"enum".fields.len, comptime countPrefixed(h, "LP_ERR_") + 1); // + LP_OK
    try testing.expectEqual(comptime countFns(@This(), "lp_"), comptime countFns(h, "lp_"));
}

fn countPrefixed(comptime T: type, comptime prefix: []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime var n: usize = 0;
    inline for (@typeInfo(T).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, prefix)) n += 1;
    }
    return n;
}

fn countFns(comptime T: type, comptime prefix: []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime var n: usize = 0;
    inline for (@typeInfo(T).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, prefix) and
            @typeInfo(@TypeOf(@field(T, decl.name))) == .@"fn") n += 1;
    }
    return n;
}

/// Opaque handles make C-vs-Zig type identity meaningless, but every
/// mismatch that matters at the call boundary shows up as an arity or a
/// size difference.
fn expectSameSignature(comptime C: type, comptime Zig: type) !void {
    const c_fn = @typeInfo(C).@"fn";
    const zig_fn = @typeInfo(Zig).@"fn";
    try testing.expectEqual(c_fn.params.len, zig_fn.params.len);
    try testing.expectEqual(@sizeOf(c_fn.return_type.?), @sizeOf(zig_fn.return_type.?));
    // Over the min so an arity drift fails the expectEqual above instead
    // of breaking the unroll.
    inline for (0..@min(c_fn.params.len, zig_fn.params.len)) |i| {
        try testing.expectEqual(@sizeOf(c_fn.params[i].type.?), @sizeOf(zig_fn.params[i].type.?));
    }
}

fn expectSameLayout(comptime C: type, comptime Zig: type) !void {
    try testing.expectEqual(@sizeOf(C), @sizeOf(Zig));
    inline for (@typeInfo(Zig).@"struct".fields) |field| {
        try testing.expectEqual(@offsetOf(C, field.name), @offsetOf(Zig, field.name));
        try testing.expectEqual(@sizeOf(@FieldType(C, field.name)), @sizeOf(field.type));
    }
}

test "c_api: defaults match the header's documented values" {
    var config = try lp.Config.init(testing.allocator, "lightpanda", .{ .embed = .{} });
    defer config.deinit(testing.allocator);
    try testing.expectEqual(5000, config.httpTimeout());
    try testing.expectEqual(30000, config.watchdogMs());
    try testing.expectEqual(5000, (lp.FetchOpts{ .dump = .{} }).wait_ms);
}

test "c_api: version matches the build" {
    try testing.expectEqualStrings(lp.build_config.version, std.mem.span(lp_version()));
}

test "c_api: tools_json is valid JSON covering every tool" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.span(lp_tools_json()),
        .{},
    );
    defer parsed.deinit();

    const list = parsed.value.array.items;
    try testing.expectEqual(lp.tools.names.len, list.len);
    for (list, lp.tools.names) |entry, name| {
        try testing.expectEqualStrings(name, entry.object.get("name").?.string);
        try testing.expect(entry.object.get("description").?.string.len > 0);
        try testing.expect(entry.object.get("inputSchema").? == .object);
    }
}

test "c_api: null handles are rejected" {
    var result: Result = .empty;
    try testing.expectEqual(.misuse, lp_init(null, null));
    try testing.expectEqual(.misuse, lp_call(null, "getUrl", "getUrl".len, null, 0, &result));
    try testing.expectEqual(.misuse, lp_session_new(null, null));
    lp_session_close(null);
    try testing.expectEqual(null, result.text);
    try testing.expectEqual(null, lp_last_error(null, null));
    try testing.expectEqual(null, lp_browser_last_error(null, null));
}

test "c_api: lifecycle" {
    var browser: *BrowserHandle = undefined;

    // Option validation happens before V8 is touched, so a rejected init
    // must leave the library initializable.
    const bad_opts: InitOpts = .{
        .user_agent = "bad\nagent",
        .user_agent_len = "bad\nagent".len,
        .http_proxy = null,
        .http_proxy_len = 0,
        .http_cache_dir = null,
        .http_cache_dir_len = 0,
        .http_timeout_ms = 0,
        .watchdog_ms = 0,
    };
    try testing.expectEqual(.invalid_params, lp_init(&bad_opts, &browser));

    try testing.expectEqual(.ok, lp_init(null, &browser));

    var second: *BrowserHandle = undefined;
    try testing.expectEqual(.misuse, lp_init(null, &second));

    var session: *SessionHandle = undefined;
    try testing.expectEqual(.ok, lp_session_new(browser, &session));

    var result: Result = .empty;
    try testing.expectEqual(.invalid_params, lp_call(session, "nosuchtool", "nosuchtool".len, null, 0, &result));
    try testing.expectEqual(.invalid_params, lp_call(session, "goto", "goto".len, null, 0, &result));
    try testing.expectEqual(.invalid_params, lp_call(session, "goto", "goto".len, "not json", "not json".len, &result));

    // The failing call left its error name behind; a successful one clears it.
    var err_len: usize = 0;
    try testing.expect(lp_last_error(session, &err_len) != null);
    try testing.expect(err_len > 0);

    try testing.expectEqual(.ok, lp_call(session, "getEnv", "getEnv".len, null, 0, &result));
    try testing.expect(result.text != null);
    try testing.expect(result.len > 0);
    _ = lp_last_error(session, &err_len);
    try testing.expectEqual(0, err_len);
    _ = lp_browser_last_error(browser, &err_len);
    try testing.expectEqual(0, err_len);

    // Lengths are the contract: trailing garbage past them must be ignored.
    const padded_tool = "getEnvGARBAGE";
    const padded_args = "{\"name\":\"PATH\"}GARBAGE";
    try testing.expectEqual(.ok, lp_call(session, padded_tool, "getEnv".len, padded_args, "{\"name\":\"PATH\"}".len, &result));
    try testing.expect(result.text != null);

    // Pumping must not invalidate a held result.
    var held: [16]u8 = undefined;
    const held_len = @min(result.len, held.len);
    @memcpy(held[0..held_len], result.text.?[0..held_len]);
    try testing.expect(lp_session_pump(session) > 0);
    try testing.expect(std.mem.eql(u8, held[0..held_len], result.text.?[0..held_len]));

    // Twice: the second call reuses the lazily-created fetch browser; the
    // second url carries trailing garbage past its length.
    try testing.expectEqual(.ok, lp_fetch(browser, "about:blank", "about:blank".len, null, &result));
    try testing.expect(result.text != null);
    try testing.expectEqual(.ok, lp_fetch(browser, "about:blankGARBAGE", "about:blank".len, null, &result));
    try testing.expect(result.len > 0);

    lp_session_close(session);
    lp_shutdown(browser);

    // Terminal: V8 cannot be re-initialized after dispose.
    try testing.expectEqual(.misuse, lp_init(null, &second));

    // Stale handles are inert after shutdown — no deref, no crash.
    try testing.expectEqual(0, lp_session_pump(session));
    lp_session_close(session);
    lp_session_set_cancel_hook(session, null, null);
}

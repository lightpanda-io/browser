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

// Mirrored in include/lightpanda.h (lp_str).
const Str = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    fn slice(self: Str) ?[]const u8 {
        const ptr = self.ptr orelse return null;
        return ptr[0..self.len];
    }
};

// Mirrored in include/lightpanda.h (lp_options). Extensible: see readOpts.
const InitOpts = extern struct {
    user_agent: Str,
    http_proxy: Str,
    http_cache_dir: Str,
    http_timeout_ms: u64,
    watchdog_ms: i64,

    // The size of the first published layout. Never changes: callers
    // passing less are bugs, not older headers.
    const min_size = 64;
};

// Mirrored in include/lightpanda.h (lp_fetch_opts). Extensible: see
// readOpts. Enums travel as plain integers so out-of-range values from C
// are rejected instead of being illegal to load.
const FetchOpts = extern struct {
    format: u64,
    wait_until: u64,
    wait_ms: u64,
    wait_selector: Str,
    wait_script: Str,
    inject_scripts: ?[*]const Str,
    inject_scripts_len: usize,
    selector: Str,
    strip: u64,
    max_bytes: u64,
    with_base: u64,
    with_frames: u64,
    fail_on_http_error: u64,
    markdown_alternate: u64,

    const min_size = 136;
};

/// Reads an options struct the caller passed with its own `size`, the way
/// Linux's `copy_struct_from_user` does: fields past a smaller caller's
/// struct read as zero (the default), and bytes past ours must be zero, so a
/// newer caller's option is refused rather than ignored.
fn readOpts(comptime T: type, ptr_: ?*const T, size: usize) error{ InvalidParams, UnsupportedOption }!T {
    var opts = std.mem.zeroes(T);
    const ptr = ptr_ orelse return if (size == 0) opts else error.InvalidParams;
    if (size < T.min_size or size % 8 != 0) return error.InvalidParams;

    const theirs: [*]const u8 = @ptrCast(ptr);
    const known = @min(size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&opts)[0..known], theirs[0..known]);
    if (std.mem.findNone(u8, theirs[known..size], &.{0}) != null) return error.UnsupportedOption;
    return opts;
}

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
    settled = 6,
};

const BrowserHandle = struct {
    config: lp.Config,
    app: *lp.App,
    // Owns the option strings duped out of the caller's InitOpts.
    config_arena: std.heap.ArenaAllocator,
    // Owns the previous lp_fetch result; reset at the start of the next one.
    fetch_arena: std.heap.ArenaAllocator,
    // lp_fetch's browser, created on first use; its isolate parks between
    // calls. Heap-allocated: Browser registers self-pointers and must not move.
    fetch_browser: ?*lp.Browser,
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
pub export fn lp_init(opts_: ?*const InitOpts, opts_size: usize, out_: ?**BrowserHandle) Status {
    const out = out_ orelse return .misuse;
    if (app_state != .uninitialized) return .misuse;

    const opts = readOpts(InitOpts, opts_, opts_size) catch |err| return errStatus(err);
    const handle = createBrowser(opts) catch |err| return errStatus(err);
    app_state = .live;
    out.* = handle;
    return .ok;
}

fn createBrowser(opts: InitOpts) !*BrowserHandle {
    const handle = try c_allocator.create(BrowserHandle);
    errdefer c_allocator.destroy(handle);

    handle.config_arena = .init(c_allocator);
    errdefer handle.config_arena.deinit();
    handle.fetch_arena = .init(c_allocator);
    errdefer handle.fetch_arena.deinit();
    const arena = handle.config_arena.allocator();

    var mode: @FieldType(lp.Config.Mode, "embed") = .{};
    if (opts.user_agent.slice()) |ua| {
        lp.Config.validateUserAgent(ua) catch return error.InvalidParams;
        mode.user_agent = try arena.dupe(u8, ua);
    }
    if (opts.http_proxy.slice()) |proxy| {
        mode.http_proxy = try arena.dupeSentinel(u8, proxy, 0);
    }
    if (opts.http_cache_dir.slice()) |dir| {
        mode.http_cache_dir = try arena.dupe(u8, dir);
    }
    if (opts.http_timeout_ms != 0) {
        mode.http_timeout = std.math.cast(u31, opts.http_timeout_ms) orelse return error.InvalidParams;
    }
    // Config.watchdogMs treats 0 as "no watchdog" and null as the default.
    if (opts.watchdog_ms < 0) {
        mode.watchdog_ms = 0;
    } else if (opts.watchdog_ms > 0) {
        mode.watchdog_ms = std.math.cast(u32, opts.watchdog_ms) orelse return error.InvalidParams;
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
    if (handle.fetch_browser) |browser| {
        // Browser.deinit's Env.deinit exit balances against this enter.
        browser.env.isolate.enter();
        browser.deinit();
        c_allocator.destroy(browser);
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
    opts_size: usize,
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
    const url = arena.dupeSentinel(u8, url_ptr[0..url_len], 0) catch return .out_of_memory;

    var fetch_opts = fetchOpts(arena, opts_, opts_size) catch |err| {
        handle.last_error = @errorName(err);
        return errStatus(err);
    };

    // Seeded so growth doubling doesn't strand superseded buffers in the
    // arena (it cannot free them); the seed itself is covered by the
    // retained chunk.
    var writer = std.Io.Writer.Allocating.initCapacity(arena, result_retain_limit) catch return .out_of_memory;
    fetch_opts.writer = &writer.writer;

    // Sessions park their isolate between calls, so entering this
    // browser's isolate here nests correctly. Browser.init leaves the
    // isolate entered; the exit below parks it either way.
    if (handle.fetch_browser) |browser| {
        browser.env.isolate.enter();
    } else {
        const browser = c_allocator.create(lp.Browser) catch return .out_of_memory;
        browser.init(handle.app, .{}) catch |err| {
            c_allocator.destroy(browser);
            handle.last_error = @errorName(err);
            return errStatus(err);
        };
        handle.fetch_browser = browser;
    }
    const browser = handle.fetch_browser.?;
    defer browser.env.isolate.exit();

    lp.fetch(handle.app, browser, &.{url}, fetch_opts) catch |err| {
        handle.last_error = @errorName(err);
        return errStatus(err);
    };

    const text = writer.written();
    out.* = .{ .text = text.ptr, .len = text.len, .is_error = false };
    return .ok;
}

/// Same rules as the `fetch` command's flag checks in main.zig.
fn fetchOpts(arena: std.mem.Allocator, opts_: ?*const FetchOpts, opts_size: usize) !lp.FetchOpts {
    const opts = try readOpts(FetchOpts, opts_, opts_size);

    const format = std.enums.fromInt(Format, opts.format) orelse return error.UnsupportedOption;
    const wait_until = std.enums.fromInt(WaitUntil, opts.wait_until) orelse return error.UnsupportedOption;
    const strip = std.math.cast(@typeInfo(lp.dump.Opts.Strip).@"struct".backing_integer.?, opts.strip) orelse return error.UnsupportedOption;

    var fetch_opts: lp.FetchOpts = .{
        .dump_mode = switch (format) {
            .html => .html,
            .markdown => .markdown,
            .tree_json => .semantic_tree,
            .tree_text => .semantic_tree_text,
        },
        .wait_until = switch (wait_until) {
            .default => null,
            .load => .load,
            .domcontentloaded => .domcontentloaded,
            .networkalmostidle => .networkalmostidle,
            .networkidle => .networkidle,
            .done => .done,
            .settled => .settled,
        },
        .dump = .{
            .strip = @bitCast(strip),
            .with_base = opts.with_base != 0,
            .with_frames = opts.with_frames != 0,
            .max_bytes = if (opts.max_bytes == 0) null else std.math.cast(u32, opts.max_bytes) orelse return error.InvalidParams,
        },
        .fail_on_http_error = opts.fail_on_http_error != 0,
        .markdown_alternate = opts.markdown_alternate != 0,
    };
    if (opts.wait_ms != 0) {
        fetch_opts.wait_ms = std.math.cast(u32, opts.wait_ms) orelse return error.InvalidParams;
    }
    if (opts.wait_selector.slice()) |selector| fetch_opts.wait_selector = try arena.dupeSentinel(u8, selector, 0);
    if (opts.wait_script.slice()) |script| fetch_opts.wait_script = try arena.dupeSentinel(u8, script, 0);
    if (opts.selector.slice()) |selector| fetch_opts.selector = try arena.dupeSentinel(u8, selector, 0);
    if (opts.inject_scripts_len > 0) {
        const scripts = opts.inject_scripts orelse return error.InvalidParams;
        try fetch_opts.inject_script.ensureTotalCapacityPrecise(arena, opts.inject_scripts_len);
        for (scripts[0..opts.inject_scripts_len]) |script| {
            fetch_opts.inject_script.appendAssumeCapacity(try arena.dupe(u8, script.slice() orelse return error.InvalidParams));
        }
    }

    if (fetch_opts.dump.max_bytes != null and format != .html and format != .markdown) return error.InvalidParams;
    if (fetch_opts.markdown_alternate and (format != .markdown or fetch_opts.selector != null)) return error.InvalidParams;
    return fetch_opts;
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
        error.InvalidParams, error.InvalidSelector, error.InvalidNodeType, error.ScriptError, error.ActionRefused => .invalid_params,
        error.NodeNotFound => .node_not_found,
        error.NavigationFailed => .navigation_failed,
        error.Cancelled => .cancelled,
        error.Timeout, error.NavigationTimeout => .timeout,
        error.InternalError => .internal,
        error.OutOfMemory => .out_of_memory,
    };
}

/// For the anyerror paths (init, fetch): tool errors keep their toolStatus
/// mapping, anything else is internal.
fn errStatus(err: anyerror) Status {
    switch (err) {
        error.UnsupportedOption => return .invalid_params,
        error.HttpError => return .navigation_failed,
        else => {},
    }
    inline for (@typeInfo(lp.tools.ToolError).error_set.error_names.?) |name| {
        const tool_err = @field(lp.tools.ToolError, name);
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

    entry.ts.session.cancel_hook = .{ .context = entry, .check = cancelTrampoline };

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

    const result = lp.tools.call(arena, entry.ts.session, &entry.ts.registry, tool[0..tool_len], args, .{ .source = .script }) catch |err| {
        entry.last_error = @errorName(err);
        return toolStatus(err);
    };

    out.* = .{ .text = result.text.ptr, .len = result.text.len, .is_error = result.is_error };
    // Argument errors come back in-band so a model can read them; a C caller
    // gets the status too, with the message still in `out`.
    if (result.failure == .invalid_params) {
        entry.last_error = @errorName(error.InvalidParams);
        return .invalid_params;
    }
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
    const entry = entry_ orelse return publishError(null, len_);
    return publishError(if (app_state == .live) entry.last_error else null, len_);
}

/// Like `lp_last_error`, for the browser-level calls (`lp_fetch`,
/// `lp_session_new`).
pub export fn lp_browser_last_error(handle_: ?*BrowserHandle, len_: ?*usize) ?[*]const u8 {
    const handle = handle_ orelse return publishError(null, len_);
    return publishError(if (app_state == .live) handle.last_error else null, len_);
}

fn publishError(err: ?[]const u8, len_: ?*usize) ?[*]const u8 {
    const e = err orelse {
        if (len_) |len| len.* = 0;
        return null;
    };
    if (len_) |len| len.* = e.len;
    return e.ptr;
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

    try testing.expectEqual(h.LP_OK, @backingInt(Status.ok));
    try testing.expectEqual(h.LP_ERR_INVALID_PARAMS, @backingInt(Status.invalid_params));
    try testing.expectEqual(h.LP_ERR_FRAME_NOT_LOADED, @backingInt(Status.frame_not_loaded));
    try testing.expectEqual(h.LP_ERR_NODE_NOT_FOUND, @backingInt(Status.node_not_found));
    try testing.expectEqual(h.LP_ERR_NAVIGATION_FAILED, @backingInt(Status.navigation_failed));
    try testing.expectEqual(h.LP_ERR_CANCELLED, @backingInt(Status.cancelled));
    try testing.expectEqual(h.LP_ERR_TIMEOUT, @backingInt(Status.timeout));
    try testing.expectEqual(h.LP_ERR_OUT_OF_MEMORY, @backingInt(Status.out_of_memory));
    try testing.expectEqual(h.LP_ERR_INTERNAL, @backingInt(Status.internal));
    try testing.expectEqual(h.LP_ERR_MISUSE, @backingInt(Status.misuse));

    try testing.expectEqual(h.LP_FORMAT_HTML, @backingInt(Format.html));
    try testing.expectEqual(h.LP_FORMAT_MARKDOWN, @backingInt(Format.markdown));
    try testing.expectEqual(h.LP_FORMAT_TREE_JSON, @backingInt(Format.tree_json));
    try testing.expectEqual(h.LP_FORMAT_TREE_TEXT, @backingInt(Format.tree_text));

    try testing.expectEqual(h.LP_WAIT_DEFAULT, @backingInt(WaitUntil.default));
    try testing.expectEqual(h.LP_WAIT_LOAD, @backingInt(WaitUntil.load));
    try testing.expectEqual(h.LP_WAIT_DOMCONTENTLOADED, @backingInt(WaitUntil.domcontentloaded));
    try testing.expectEqual(h.LP_WAIT_NETWORKALMOSTIDLE, @backingInt(WaitUntil.networkalmostidle));
    try testing.expectEqual(h.LP_WAIT_NETWORKIDLE, @backingInt(WaitUntil.networkidle));
    try testing.expectEqual(h.LP_WAIT_DONE, @backingInt(WaitUntil.done));
    try testing.expectEqual(h.LP_WAIT_SETTLED, @backingInt(WaitUntil.settled));

    const strip_bits = .{ .{ h.LP_STRIP_JS, "js" }, .{ h.LP_STRIP_UI, "ui" }, .{ h.LP_STRIP_CSS, "css" }, .{ h.LP_STRIP_INVISIBLE, "invisible" }, .{ h.LP_STRIP_SHELL, "shell" }, .{ h.LP_STRIP_CLUTTER, "clutter" } };
    inline for (strip_bits) |bit| {
        try testing.expectEqual(bit[0], 1 << @bitOffsetOf(lp.dump.Opts.Strip, bit[1]));
    }
    try testing.expectEqual(@typeInfo(lp.dump.Opts.Strip).@"struct".field_names.len, strip_bits.len);

    try expectSameLayout(h.lp_result, Result);
    try expectSameLayout(h.lp_str, Str);
    try expectSameLayout(h.lp_options, InitOpts);
    try expectSameLayout(h.lp_fetch_opts, FetchOpts);

    // The exports are pub so this reflection sees them; a header prototype
    // must exist (compile error otherwise) and agree on arity and sizes.
    inline for (@typeInfo(@This()).@"struct".decl_names) |name| {
        if (comptime std.mem.startsWith(u8, name, "lp_")) {
            try expectSameSignature(@TypeOf(@field(h, name)), @TypeOf(@field(@This(), name)));
        }
    }

    // The lines above only prove the Zig side exists in the header; the
    // counts catch a constant or function added to the header alone.
    try testing.expectEqual(@typeInfo(Format).@"enum".field_names.len, comptime countPrefixed(h, "LP_FORMAT_"));
    try testing.expectEqual(@typeInfo(WaitUntil).@"enum".field_names.len, comptime countPrefixed(h, "LP_WAIT_"));
    try testing.expectEqual(strip_bits.len, comptime countPrefixed(h, "LP_STRIP_"));
    try testing.expectEqual(@typeInfo(Status).@"enum".field_names.len, comptime countPrefixed(h, "LP_ERR_") + 1); // + LP_OK
    try testing.expectEqual(comptime countFns(@This(), "lp_"), comptime countFns(h, "lp_"));
}

fn countPrefixed(comptime T: type, comptime prefix: []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime var n: usize = 0;
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        if (comptime std.mem.startsWith(u8, name, prefix)) n += 1;
    }
    return n;
}

fn countFns(comptime T: type, comptime prefix: []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime var n: usize = 0;
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        if (comptime std.mem.startsWith(u8, name, prefix) and
            @typeInfo(@TypeOf(@field(T, name))) == .@"fn") n += 1;
    }
    return n;
}

/// Opaque handles make C-vs-Zig type identity meaningless, but every
/// mismatch that matters at the call boundary shows up as an arity or a
/// size difference.
fn expectSameSignature(comptime C: type, comptime Zig: type) !void {
    const c_fn = @typeInfo(C).@"fn";
    const zig_fn = @typeInfo(Zig).@"fn";
    try testing.expectEqual(c_fn.param_types.len, zig_fn.param_types.len);
    try testing.expectEqual(@sizeOf(c_fn.return_type.?), @sizeOf(zig_fn.return_type.?));
    // Over the min so an arity drift fails the expectEqual above instead
    // of breaking the unroll.
    inline for (0..@min(c_fn.param_types.len, zig_fn.param_types.len)) |i| {
        try testing.expectEqual(@sizeOf(c_fn.param_types[i].?), @sizeOf(zig_fn.param_types[i].?));
    }
}

fn expectSameLayout(comptime C: type, comptime Zig: type) !void {
    try testing.expectEqual(@sizeOf(C), @sizeOf(Zig));
    const info = @typeInfo(Zig).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        try testing.expectEqual(@offsetOf(C, name), @offsetOf(Zig, name));
        try testing.expectEqual(@sizeOf(@FieldType(C, name)), @sizeOf(T));
    }
}

test "c_api: options structs stay extensible" {
    inline for (.{ InitOpts, FetchOpts }) |T| {
        // An appended field landing in padding would leave sizeof unchanged,
        // and an older caller's garbage padding would read as that field.
        const info = @typeInfo(T).@"struct";
        comptime var fields_size: usize = 0;
        inline for (info.field_types) |F| {
            try testing.expectEqual(8, @alignOf(F));
            fields_size += @sizeOf(F);
        }
        try testing.expectEqual(@sizeOf(T), fields_size);
        try testing.expect(T.min_size <= @sizeOf(T));
    }
    try testing.expectEqual(@sizeOf(Str), 16);
}

test "c_api: every lp.FetchOpts field is mirrored or excluded" {
    // Adding a field to lp.FetchOpts (or dump.Opts) fails here until it is
    // either exposed in lp_fetch_opts or listed with a reason below.
    const mirrored = .{
        "wait_ms",            "wait_until",         "wait_script", "inject_script",
        "wait_selector",      "dump",               "dump_mode",   "selector",
        "fail_on_http_error", "markdown_alternate",
    };
    const excluded = .{
        "png_mode", // no PNG format exposed
        "writer", // the result buffer
        "json", // the CLI's multi-url output envelope
    };
    try expectFieldsCovered(lp.FetchOpts, mirrored ++ excluded);

    const dump_mirrored = .{ "with_base", "with_frames", "strip", "max_bytes" };
    const dump_excluded = .{
        "shadow", // the CLI doesn't expose it either
        "pruned", // set internally by clutter removal
    };
    try expectFieldsCovered(lp.dump.Opts, dump_mirrored ++ dump_excluded);
}

fn expectFieldsCovered(comptime T: type, comptime names: anytype) !void {
    const fields = @typeInfo(T).@"struct".field_names;
    try testing.expectEqual(fields.len, names.len);
    inline for (fields) |field| {
        comptime var found = false;
        inline for (names) |name| {
            if (comptime std.mem.eql(u8, field, name)) found = true;
        }
        if (!found) {
            std.debug.print("{s}.{s} is neither mirrored in lp_fetch_opts nor excluded\n", .{ @typeName(T), field });
            return error.TestUnexpectedResult;
        }
    }
}

test "c_api: readOpts size handling" {
    const zero = std.mem.zeroes(InitOpts);
    try testing.expectEqual(zero, try readOpts(InitOpts, null, 0));
    try testing.expectError(error.InvalidParams, readOpts(InitOpts, null, 8));

    var opts = zero;
    opts.http_timeout_ms = 1234;
    try testing.expectEqual(1234, (try readOpts(InitOpts, &opts, @sizeOf(InitOpts))).http_timeout_ms);
    // Too small to be any published layout, or not field-aligned.
    try testing.expectError(error.InvalidParams, readOpts(InitOpts, &opts, 8));
    try testing.expectError(error.InvalidParams, readOpts(InitOpts, &opts, @sizeOf(InitOpts) - 4));

    // A newer caller: unknown trailing fields are fine while zero, refused
    // once set.
    const Newer = extern struct { known: InitOpts, extra: u64 };
    var newer: Newer = .{ .known = opts, .extra = 0 };
    const as_known: *const InitOpts = @ptrCast(&newer);
    try testing.expectEqual(1234, (try readOpts(InitOpts, as_known, @sizeOf(Newer))).http_timeout_ms);
    newer.extra = 1;
    try testing.expectError(error.UnsupportedOption, readOpts(InitOpts, as_known, @sizeOf(Newer)));
}

test "c_api: fetch options map onto lp.FetchOpts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const defaults = try fetchOpts(allocator, null, 0);
    try testing.expectEqual(.html, defaults.dump_mode.?);
    try testing.expectEqual(null, defaults.wait_until);
    try testing.expectEqual(5000, defaults.wait_ms);

    const scripts = [_]Str{.{ .ptr = "window.x = 1", .len = "window.x = 1".len }};
    var opts = std.mem.zeroes(FetchOpts);
    opts.format = @backingInt(Format.markdown);
    opts.wait_until = @backingInt(WaitUntil.settled);
    opts.wait_ms = 100;
    opts.wait_selector = .{ .ptr = "#main", .len = "#main".len };
    opts.inject_scripts = &scripts;
    opts.inject_scripts_len = scripts.len;
    opts.strip = 0b100001; // js | clutter
    opts.max_bytes = 4096;
    opts.markdown_alternate = 1;
    const mapped = try fetchOpts(allocator, &opts, @sizeOf(FetchOpts));
    try testing.expectEqual(.markdown, mapped.dump_mode.?);
    try testing.expectEqual(.settled, mapped.wait_until.?);
    try testing.expectEqual(100, mapped.wait_ms);
    try testing.expectEqualStrings("#main", mapped.wait_selector.?);
    try testing.expectEqualStrings("window.x = 1", mapped.inject_script.items[0]);
    try testing.expectEqual(lp.dump.Opts.Strip{ .js = true, .clutter = true }, mapped.dump.strip);
    try testing.expectEqual(4096, mapped.dump.max_bytes.?);
    try testing.expect(mapped.markdown_alternate);

    // Values this library doesn't know are refused, not clamped.
    var bad = std.mem.zeroes(FetchOpts);
    bad.format = 99;
    try testing.expectError(error.UnsupportedOption, fetchOpts(allocator, &bad, @sizeOf(FetchOpts)));
    bad = std.mem.zeroes(FetchOpts);
    bad.strip = 1 << 6;
    try testing.expectError(error.UnsupportedOption, fetchOpts(allocator, &bad, @sizeOf(FetchOpts)));

    // The fetch command's combination rules.
    bad = std.mem.zeroes(FetchOpts);
    bad.markdown_alternate = 1;
    try testing.expectError(error.InvalidParams, fetchOpts(allocator, &bad, @sizeOf(FetchOpts)));
    bad = std.mem.zeroes(FetchOpts);
    bad.format = @backingInt(Format.tree_json);
    bad.max_bytes = 10;
    try testing.expectError(error.InvalidParams, fetchOpts(allocator, &bad, @sizeOf(FetchOpts)));
}

test "c_api: defaults match the header's documented values" {
    var config = try lp.Config.init(testing.allocator, "lightpanda", .{ .embed = .{} });
    defer config.deinit(testing.allocator);
    try testing.expectEqual(15000, config.httpTimeout());
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
    try testing.expectEqual(.misuse, lp_init(null, 0, null));
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
    var bad_opts = std.mem.zeroes(InitOpts);
    bad_opts.user_agent = .{ .ptr = "bad\nagent", .len = "bad\nagent".len };
    try testing.expectEqual(.invalid_params, lp_init(&bad_opts, @sizeOf(InitOpts), &browser));

    try testing.expectEqual(.ok, lp_init(null, 0, &browser));

    var second: *BrowserHandle = undefined;
    try testing.expectEqual(.misuse, lp_init(null, 0, &second));

    var session: *SessionHandle = undefined;
    try testing.expectEqual(.ok, lp_session_new(browser, &session));

    var result: Result = .empty;
    // Unknown tool names come back in-band (is_error) so an LLM caller can
    // read them; see tools.call.
    try testing.expectEqual(.ok, lp_call(session, "nosuchtool", "nosuchtool".len, null, 0, &result));
    try testing.expect(result.is_error);
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
    try testing.expectEqual(.ok, lp_fetch(browser, "about:blank", "about:blank".len, null, 0, &result));
    try testing.expect(result.text != null);
    var fetch_opts = std.mem.zeroes(FetchOpts);
    fetch_opts.format = @backingInt(Format.markdown);
    try testing.expectEqual(.ok, lp_fetch(browser, "about:blankGARBAGE", "about:blank".len, &fetch_opts, @sizeOf(FetchOpts), &result));

    // An option this build doesn't know fails with its name left behind.
    fetch_opts.format = 99;
    try testing.expectEqual(.invalid_params, lp_fetch(browser, "about:blank", "about:blank".len, &fetch_opts, @sizeOf(FetchOpts), &result));
    var name_len: usize = 0;
    const name = lp_browser_last_error(browser, &name_len).?;
    try testing.expectEqualStrings("UnsupportedOption", name[0..name_len]);

    lp_session_close(session);
    lp_shutdown(browser);

    // Terminal: V8 cannot be re-initialized after dispose.
    try testing.expectEqual(.misuse, lp_init(null, 0, &second));

    // Stale handles are inert after shutdown — no deref, no crash.
    try testing.expectEqual(0, lp_session_pump(session));
    lp_session_close(session);
    lp_session_set_cancel_hook(session, null, null);
}

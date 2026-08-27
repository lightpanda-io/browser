// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

pub const log = @import("log.zig");
pub const datetime = @import("datetime.zig");
pub const App = @import("App.zig");
pub const Arena = @import("Arena.zig");
pub const ArenaPool = @import("ArenaPool.zig");
pub const Network = @import("network/Network.zig");
pub const Server = @import("Server.zig");
pub const Config = @import("Config.zig");
pub const String = @import("string.zig").String;
pub const Notification = @import("Notification.zig");

pub const URL = @import("browser/URL.zig");
pub const Page = @import("browser/Page.zig");
pub const Frame = @import("browser/Frame.zig");
pub const Browser = @import("browser/Browser.zig");
pub const Session = @import("browser/Session.zig");

pub const js = @import("browser/js/js.zig");
pub const dump = @import("browser/dump.zig");
pub const markdown = @import("browser/markdown.zig");
pub const screenshot = @import("browser/screenshot.zig");
pub const Base64Writer = @import("Base64Writer.zig");
const Selector = @import("browser/webapi/selector/Selector.zig");
const Node = @import("browser/webapi/Node.zig");
pub const SemanticTree = @import("SemanticTree.zig");
pub const CDPNode = @import("cdp/Node.zig");
pub const interactive = @import("browser/interactive.zig");
pub const links = @import("browser/links.zig");
pub const forms = @import("browser/forms.zig");
pub const actions = @import("browser/actions.zig");
pub const structured_data = @import("browser/structured_data.zig");
pub const tools = @import("browser/tools.zig");
pub const HttpClient = @import("network/HttpClient.zig");

pub const mcp = @import("mcp.zig");
pub const Agent = @import("agent/Agent.zig");
pub const Command = @import("script/command.zig").Command;
pub const Recorder = @import("script/Recorder.zig");
pub const Runtime = @import("script/Runtime.zig");
pub const Schema = @import("script/Schema.zig");
pub const skill = @import("script/skill.zig");
pub const cookies = @import("cookies.zig");
pub const build_config = @import("build_config");
pub const crash_handler = @import("crash_handler.zig");
pub const core_dump = @import("core_dump.zig");

pub var metrics = @import("Metrics.zig"){};

pub const IS_TEST = @import("builtin").is_test;
pub const IS_DEBUG = @import("builtin").mode == .Debug;

/// Process-wide Io instance for blocking syscalls (fs, net, time, futex).
/// Single-threaded-init only disables Io.async/Io.concurrent task spawning;
/// blocking operations work from any thread.
var io_threaded: std.Io.Threaded = .init_single_threaded;
pub const io: std.Io = io_threaded.io();

/// The single-threaded Io instance carries an empty environ; consumers that
/// need the real process environment (env-var lookups, spawned children) use
/// this instead.
pub fn environ() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

/// Environ.Map view of `environ` for spawned children that should inherit the
/// process environment (argv[0] PATH resolution always uses the parent
/// environment regardless).
pub fn environMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return environ().createMap(allocator);
}

/// Io.Condition has no timed wait (@ZIG16: delete when std grows one).
/// Mirrors std's Condition.waitInner with a deadline-bounded futex wait.
/// Not a cancelation point. Returns error.Timeout when no signal arrives.
pub fn timedWait(cond: *std.Io.Condition, mutex: *std.Io.Mutex, timeout_ns: u64) error{Timeout}!void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .raw = .fromNanoseconds(@intCast(timeout_ns)),
        .clock = .awake,
    });

    var epoch = cond.epoch.load(.acquire);
    _ = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);

    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    while (true) {
        io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, .{ .deadline = deadline }) catch {};
        epoch = cond.epoch.load(.acquire);

        // Consume a pending signal even after a timeout-shaped wake, so a
        // signal never gets stuck in the state with no waiter (same race
        // std's waitInner defends against).
        var prev_state = cond.state.load(.monotonic);
        while (prev_state.signals > 0) {
            prev_state = cond.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters - 1,
                .signals = prev_state.signals - 1,
            }, .acquire, .monotonic) orelse return;
        }

        if (deadline.compare(.lte, .now(io, .awake))) {
            _ = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            return error.Timeout;
        }
    }
}

/// Drop-in for the removed std.Thread.WaitGroup (start/finish/wait subset).
pub const WaitGroup = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *WaitGroup) void {
        _ = self.state.fetchAdd(1, .monotonic);
    }

    pub fn startMany(self: *WaitGroup, n: u32) void {
        _ = self.state.fetchAdd(n, .monotonic);
    }

    pub fn finish(self: *WaitGroup) void {
        if (self.state.fetchSub(1, .acq_rel) == 1) {
            io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
        }
    }

    pub fn wait(self: *WaitGroup) void {
        while (true) {
            const n = self.state.load(.acquire);
            if (n == 0) {
                return;
            }
            io.futexWaitUncancelable(u32, &self.state.raw, n);
        }
    }
};

/// Drop-in for the removed std.once: `f` runs exactly once; concurrent
/// callers block until the first call completes.
pub fn once(comptime f: fn () void) Once(f) {
    return .{};
}

pub fn Once(comptime f: fn () void) type {
    return struct {
        done: bool = false,
        mutex: std.Io.Mutex = .init,

        pub fn call(self: *@This()) void {
            if (@atomicLoad(bool, &self.done, .acquire)) {
                return;
            }
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (!self.done) {
                f();
                @atomicStore(bool, &self.done, true, .release);
            }
        }
    };
}

pub const FetchOpts = struct {
    wait_ms: u32 = 5000,
    wait_until: ?Config.WaitUntil = null,
    wait_script: ?[:0]const u8 = null,
    inject_script: std.ArrayList([]const u8) = .empty,
    wait_selector: ?[:0]const u8 = null,
    dump: dump.Opts,
    dump_mode: ?Config.DumpFormat = null,
    /// Dump only the first match instead of the document.
    selector: ?[:0]const u8 = null,
    /// Any page with an HTTP status >= 400 fails the fetch with `error.HttpError`.
    fail_on_http_error: bool = false,
    writer: ?*std.Io.Writer = null,
    json: bool = false,
};

/// `.load`, not `.done`: pages with constant background activity never go
/// quiescent, so `.done` just rides the `wait_ms` cap. A lone
/// `wait_selector`/`wait_script` is itself the wait, so no level applies
/// unless given explicitly.
fn resolveWaitUntil(opts: FetchOpts) ?Config.WaitUntil {
    if (opts.wait_until) |wu| return wu;
    if (opts.wait_selector == null and opts.wait_script == null) return .load;
    return null;
}
/// Loads each url in `urls` in a fresh session and waits per `opts`.
///
/// A page's navigation, wait or dump failure is recorded for that page and
/// does not stop the others: every page is still written (JSON carries the
/// failure under `error`), then the first failure is returned. Wait failures
/// are `error.Timeout` when the deadline expires while a `wait_selector` or
/// `wait_script` is still unmet (the `wait_until` phase never raises it: when
/// the budget runs out the page is dumped as-is), or `error.Cancelled` if the
/// embedder's opt-in `Session.cancel_hook` returned true.
pub fn fetch(app: *App, browser: *Browser, urls: []const [:0]const u8, opts: FetchOpts) !void {
    const notification = try Notification.init(app.allocator);
    defer notification.deinit();

    var session = try browser.newSession(notification);
    // Session.deinit unregisters from notification; close before notification.deinit runs.
    defer browser.closeSession();

    if (app.config.cookieFile()) |cookie_path| {
        cookies.loadFromFile(session, cookie_path);
    }

    defer {
        if (app.config.cookieJarFile()) |cookie_jar_path| {
            cookies.saveToFile(&session.cookie_jar, cookie_jar_path);
        }
    }

    // Stash scripts user want to inject.
    session.inject_scripts = opts.inject_script.items;

    // One page per url. `PageHandle.frame()` always re-resolves the live frame,
    // so the handles stay valid across navigate / wait. The Runner's wait paths
    // already operate over every live page in the session.
    var pages: std.ArrayList(Session.PageHandle) = try .initCapacity(session.arena.allocator(), urls.len);
    for (urls) |url| {
        const page = try session.createPage();
        const frame = page.frame().?;
        // not guaranteed to be valid after navigate
        const encoded_url = try URL.resolveNavigation(frame.call_arena, url, .{});
        _ = try frame.navigate(encoded_url, .{
            .reason = .address_bar,
            .kind = .{ .push = null },
        });
        pages.appendAssumeCapacity(page);
    }

    // // Both profilers are debug-only (`@compileError` in the start functions)
    // // and cover pages.items[0], so pass a single url.

    // // Uncomment to get a profile of the JS code. You can open this in
    // // Chrome's profiler. I've seen it generate invalid JSON, but I'm not
    // // sure why. It happens rarely, and I manually fix the file.
    // pages.items[0].frame().?.js.startCpuProfiler();
    // defer {
    //     if (pages.items[0].frame().?.js.stopCpuProfiler()) |profile| {
    //         std.Io.Dir.cwd().writeFile(io, .{
    //             .sub_path = ".lp-cache/cpu_profile.json",
    //             .data = profile,
    //         }) catch |err| {
    //             log.err(.app, "profile write error", .{ .err = err });
    //         };
    //     } else |err| {
    //         log.err(.app, "profile error", .{ .err = err });
    //     }
    // }

    // // Uncomment to get a V8 heap profile. The snapshot opens in Chrome's
    // // Memory tab, which is where the retainer breakdown lives.
    // pages.items[0].frame().?.js.startHeapProfiler();
    // defer {
    //     if (pages.items[0].frame().?.js.stopHeapProfiler()) |profile| {
    //         std.Io.Dir.cwd().writeFile(io, .{
    //             .sub_path = ".lp-cache/allocating.heapprofile",
    //             .data = profile.@"0",
    //         }) catch |err| {
    //             log.err(.app, "allocating write error", .{ .err = err });
    //         };
    //         std.Io.Dir.cwd().writeFile(io, .{
    //             .sub_path = ".lp-cache/snapshot.heapsnapshot",
    //             .data = profile.@"1",
    //         }) catch |err| {
    //             log.err(.app, "heapsnapshot write error", .{ .err = err });
    //         };
    //     } else |err| {
    //         log.err(.app, "profile error", .{ .err = err });
    //     }
    // }

    var runner = session.runner(.{});

    var timer: std.Io.Timestamp = .now(io, .boot);

    if (resolveWaitUntil(opts)) |wu| {
        try runner.waitForAll(opts.wait_ms, .{ .until = wu });
    }

    // One slot per page; the first failure sticks.
    const errors = try session.arena.allocator().alloc(?anyerror, pages.items.len);
    @memset(errors, null);

    if (opts.wait_selector) |selector| {
        for (pages.items, errors) |page, *err| {
            if (err.* != null) continue;
            const frame = page.frame() orelse {
                err.* = error.FrameClosed;
                continue;
            };
            const remaining = opts.wait_ms -| @as(u32, @intCast(timer.untilNow(io, .boot).toMilliseconds()));
            _ = runner.waitForSelector(frame._frame_id, selector, remaining) catch |e| {
                err.* = e;
            };
        }
    }

    if (opts.wait_script) |wait_script| {
        for (pages.items, errors) |page, *err| {
            if (err.* != null) continue;
            const frame = page.frame() orelse {
                err.* = error.FrameClosed;
                continue;
            };
            const remaining = opts.wait_ms -| @as(u32, @intCast(timer.untilNow(io, .boot).toMilliseconds()));
            runner.waitForScript(frame._frame_id, wait_script, remaining) catch |e| {
                err.* = e;
            };
        }
    }

    var http_error = false;
    for (pages.items, errors) |page, *err| {
        const frame = page.frame() orelse {
            if (err.* == null) {
                err.* = error.FrameClosed;
            }
            continue;
        };
        if (err.* == null) {
            err.* = frame._last_navigate_error;
        }
        if (frame._http_status) |status| {
            if (status >= 400) {
                http_error = true;
            }
        }
    }

    try writeResults(app, opts, pages.items, errors);

    var failed = false;
    for (urls, pages.items, errors) |url, page, err| {
        if (err) |e| {
            failed = true;
            log.err(.app, "page failed", .{ .url = url, .err = e });
            continue;
        }
        if (!opts.fail_on_http_error) {
            continue;
        }
        const frame = page.frame() orelse continue;
        const status = frame._http_status orelse continue;
        if (status >= 400) {
            log.err(.app, "page http error", .{ .url = url, .status = status });
        }
    }
    if (failed) {
        return error.PageFailed;
    }
    if (opts.fail_on_http_error and http_error) {
        return error.HttpError;
    }
}

fn writeResults(app: *App, opts: FetchOpts, pages: []const Session.PageHandle, errors: []?anyerror) !void {
    const writer = opts.writer orelse return;

    if (opts.json) {
        // A single url keeps the original bare-object output. Multiple urls are
        // wrapped in an extensible `{"results": [...]}` envelope: a bare
        // top-level array is hard to evolve (consumers index it directly),
        // whereas an object lets us add sibling fields later without breaking
        // anyone reading `results`.
        const wrap = pages.len > 1;
        if (wrap) {
            try writer.writeAll("{\"results\":[");
        }
        for (pages, errors, 0..) |page, *err, i| {
            if (i != 0) {
                try writer.writeByte(',');
            }

            const frame = page.frame();
            if (opts.dump_mode == .png and frame != null) {
                const arena = try app.arena_pool.acquire(.large, "screenshot.dump");
                defer arena.release();

                if (prepareShot(arena.allocator(), frame.?, opts)) |shot| {
                    try writeJsonEnvelope(writer, frame, opts.dump_mode, shot, err.*);
                } else |e| {
                    if (err.* == null) err.* = e;
                    try writeJsonEnvelope(writer, frame, opts.dump_mode, "", err.*);
                }
                continue;
            }

            var aw: std.Io.Writer.Allocating = .init(app.allocator);
            defer aw.deinit();

            if (opts.dump_mode) |mode| {
                if (frame) |f| dumpContent(app, mode, opts, f, &aw.writer) catch |e| {
                    aw.clearRetainingCapacity();
                    if (err.* == null) err.* = e;
                };
            }
            try writeJsonEnvelope(writer, frame, opts.dump_mode, aw.written(), err.*);
        }
        if (wrap) {
            try writer.writeAll("]}");
        }
        try writer.writeByte('\n');
    } else {
        // main validates that non-JSON dump is only reached with a single url.
        const page = pages[0];
        if (opts.dump_mode) |mode| blk: {
            const frame = page.frame() orelse {
                try writer.writeAll("Frame closed. Please open a bug report including the URL\n");
                break :blk;
            };
            try dumpContent(app, mode, opts, frame, writer);
        }
    }
    try writer.flush();
}

fn prepareShot(arena: std.mem.Allocator, frame: *Frame, opts: FetchOpts) !screenshot.Prepared {
    return screenshot.prepare(arena, try dumpRoot(frame, opts.selector), .fromViewport(frame._page.getViewport(), true), frame);
}

fn dumpRoot(frame: *Frame, selector: ?[]const u8) !*Node {
    const document = frame.window._document.asNode();
    const sel = selector orelse return document;
    const element = try Selector.querySelector(document, sel, frame);
    return (element orelse return error.SelectorNotFound).asNode();
}

fn dumpContent(app: *App, mode: Config.DumpFormat, opts: FetchOpts, frame: *Frame, writer: *std.Io.Writer) !void {
    const root = try dumpRoot(frame, opts.selector);
    switch (mode) {
        .html => if (opts.selector == null)
            try dump.root(frame.window._document, opts.dump, writer, frame)
        else
            try dump.deep(root, opts.dump, writer, frame),
        .markdown => try markdown.dump(root, .{ .max_bytes = opts.dump.max_bytes, .strip = opts.dump.strip }, writer, frame),
        .png => {
            var arena: std.heap.ArenaAllocator = .init(app.allocator);
            defer arena.deinit();
            _ = try screenshot.png(arena.allocator(), root, .fromViewport(frame._page.getViewport(), true), writer, frame);
        },
        .semantic_tree, .semantic_tree_text => {
            var registry = CDPNode.Registry.init(app.allocator);
            defer registry.deinit();

            const st: SemanticTree = .{
                .dom_node = root,
                .registry = &registry,
                .frame = frame,
                .arena = frame.call_arena,
                .prune = (mode == .semantic_tree_text),
            };

            if (mode == .semantic_tree) {
                try std.json.Stringify.value(st, .{}, writer);
            } else {
                try st.textStringify(writer);
            }
        },
        .wpt => try dumpWPT(frame, writer),
    }
}

pub fn checkVersion(allocator: std.mem.Allocator, config: *const Config) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    try @import("Updater.zig").inform(allocator, config, &writer.interface);
}

// Writes a single page's result object. Framing (the enclosing array and any
// separators / trailing newline) is the caller's responsibility.
fn writeJsonEnvelope(writer: *std.Io.Writer, frame: ?*Frame, dump_mode: ?Config.DumpFormat, content: anytype, err: ?anyerror) !void {
    const meta: ?Frame.HttpMetadata = if (frame) |f| f.httpMetadata() else null;
    try std.json.Stringify.value(.{
        .url = if (meta) |m| m.url else "",
        .http_status = if (meta) |m| m.status orelse 0 else 0,
        .headers = if (meta) |m| m.headers else &.{},
        .dump = if (dump_mode) |mode| @tagName(mode) else "",
        .content = content,
        .@"error" = if (err) |e| @errorName(e) else null,
    }, .{}, writer);
}

fn dumpWPT(frame: *Frame, writer: *std.Io.Writer) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // return the detailed result.
    const dump_script =
        \\ JSON.stringify((() => {
        \\   const statuses = ['Pass', 'Fail', 'Timeout', 'Not Run', 'Optional Feature Unsupported'];
        \\   const parse = (raw) => {
        \\     for (const status of statuses) {
        \\       const idx = raw.indexOf('|' + status);
        \\       if (idx !== -1) {
        \\         const name = raw.slice(0, idx);
        \\         const rest = raw.slice(idx + status.length + 1);
        \\         const message = rest.length > 0 && rest[0] === '|' ? rest.slice(1) : null;
        \\         return { name, status, message };
        \\       }
        \\     }
        \\     return { name: raw, status: 'Unknown', message: null };
        \\   };
        \\   const cases = Object.values(report.cases).map(parse);
        \\   return {
        \\     url: window.location.href,
        \\     status: report.status,
        \\     message: report.message,
        \\     summary: {
        \\       total: cases.length,
        \\       passed: cases.filter(c => c.status === 'Pass').length,
        \\       failed: cases.filter(c => c.status === 'Fail').length,
        \\       timeout: cases.filter(c => c.status === 'Timeout').length,
        \\       notrun: cases.filter(c => c.status === 'Not Run').length,
        \\       unsupported: cases.filter(c => c.status === 'Optional Feature Unsupported').length
        \\     },
        \\     not_passed: cases.filter(c => c.status !== 'Pass')
        \\   };
        \\ })(), null, 2)
    ;
    const value = ls.local.exec(dump_script, "dump_script") catch |err| {
        const caught = try_catch.caughtOrError(frame.call_arena, err);
        return writer.print("Caught error trying to access WPT's report: {f}\n", .{caught});
    };
    try writer.writeAll("== WPT Results==\n");
    try writer.writeAll(try value.toStringSliceWithAlloc(frame.call_arena));
}

pub inline fn assert(ok: bool, comptime ctx: []const u8, args: anytype) void {
    if (!ok) {
        assertionFailure(ctx, args);
    }
}

noinline fn assertionFailure(comptime ctx: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint("assertion failure: " ++ ctx, args));
    }
    @import("crash_handler.zig").crash(ctx, args, @returnAddress());
}

// Written into every RC at construction (rc_canary) and overwritten with
// rc_poison on the final release. We only get crash reports (not logs) from
// prod, so reading _canary in the "release overflow" assert tells us which kind
// of bug it is:
//   - rc_canary ("RCNT"): the struct still looks live -> a real refcount
//     accounting bug, OR the memory was reused by a freshly-built RC (which
//     re-stamps the canary, so this case can't be fully ruled out).
//   - rc_poison ("DEADC0DE"): a stale finalizer fired again on an object we
//     already released, before its memory was reused -> UAF.
//   - anything else: the memory was freed and reused by non-RC data -> UAF.
const rc_canary: u32 = 0x52434E54;
const rc_poison: u32 = 0xDEADC0DE;

// Reference counting helper. The count is a u32: a u8 silently wrapped at 256
// concurrent refs (e.g. hundreds of live iterators on one URLSearchParams),
// causing a premature deinit and a poisoned "release overflow" crash.
pub const RC = struct {
    _refs: std.atomic.Value(u32) = .init(0),
    _canary: u32 = rc_canary,

    pub fn init(refs: u32) RC {
        return .{ ._refs = .init(refs) };
    }

    pub fn acquire(self: *RC) void {
        _ = self._refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *RC, value: anytype, page: *Page) void {
        const prev = self._refs.fetchSub(1, .acq_rel);
        assert(prev > 0, "release overflow", .{
            .type = @typeName(@TypeOf(value)),
            .canary = self._canary, // rc_canary=live/accounting, rc_poison=double-release, else=reuse
            .refs = prev,
            .ptr = @intFromPtr(value),
        });
        if (prev == 1) {
            // Mark dead before deinit frees this memory, so a stale
            // weak-callback re-fire reads rc_poison instead of a
            // misleadingly-intact canary.
            self._canary = rc_poison;
            value.deinit(page);
        }
    }

    pub fn format(self: RC, writer: *std.Io.Writer) !void {
        return writer.print("{d}", .{self._refs.load(.monotonic)});
    }
};

const testing = @import("testing.zig");
test "writeJsonEnvelope: null frame" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeJsonEnvelope(&aw.writer, null, null, "", null);
    try testing.expectJson(.{
        .url = "",
        .http_status = 0,
        .dump = "",
        .content = "",
    }, aw.written());
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"error\":null") != null);
}

test "writeJsonEnvelope: page error" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeJsonEnvelope(&aw.writer, null, .markdown, "", error.Timeout);
    try testing.expectJson(.{
        .dump = "markdown",
        .content = "",
        .@"error" = "Timeout",
    }, aw.written());
}

test "writeJsonEnvelope: null frame with dump mode and content" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeJsonEnvelope(&aw.writer, null, .html, "<html><body>hello</body></html>", null);
    try testing.expectJson(.{
        .dump = "html",
        .content = "<html><body>hello</body></html>",
    }, aw.written());
}

test "fetch: resolveWaitUntil" {
    try testing.expectEqual(.load, resolveWaitUntil(.{ .dump = .{} }));
    try testing.expectEqual(.done, resolveWaitUntil(.{ .dump = .{}, .wait_until = .done }));
    try testing.expectEqual(null, resolveWaitUntil(.{ .dump = .{}, .wait_selector = "#main" }));
    try testing.expectEqual(null, resolveWaitUntil(.{ .dump = .{}, .wait_script = "true" }));
    try testing.expectEqual(
        .networkidle,
        resolveWaitUntil(.{ .dump = .{}, .wait_until = .networkidle, .wait_selector = "#main" }),
    );
}

test {
    std.testing.refAllDecls(@This());
}

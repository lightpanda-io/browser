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
const lp = @import("lightpanda");
const http = @import("network/http.zig");
const sys_net = @import("sys/net.zig");
const libcurl = @import("sys/libcurl.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const io = std.testing.io;
pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expect = std.testing.expect;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;

// sometimes it's super useful to have an arena you don't really care about
// in a test. Like, you need a mutable string, so you just want to dupe a
// string literal. It has nothing to do with the code under test, it's just
// infrastructure for the test itself.
var arena_instance = std.heap.ArenaAllocator.init(std.heap.c_allocator);
pub const arena_allocator = arena_instance.allocator();

pub fn reset() void {
    _ = arena_instance.reset(.retain_capacity);
}

/// Path of `name` inside a std.testing.tmpDir, relative to the cwd like the
/// tmpDir itself, since some tools refuse absolute paths.
pub fn tmpPath(tmp: *const std.testing.TmpDir, name: []const u8) ![:0]const u8 {
    return std.Io.Dir.path.joinZ(arena_allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

const App = @import("App.zig");
const js = @import("browser/js/js.zig");
const Config = @import("Config.zig");
const Frame = @import("browser/Frame.zig");
const Browser = @import("browser/Browser.zig");
const Session = @import("browser/Session.zig");
const Notification = @import("Notification.zig");

// Merged std.testing.expectEqual and std.testing.expectString
// can be useful when testing fields of an anytype an you don't know
// exactly how to assert equality
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .array => |arr| if (arr.child == u8) {
            return std.testing.expectEqualStrings(expected, &actual);
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (comptime isStringArray(ptr.child)) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (ptr.child == []u8 or ptr.child == []const u8) {
                return expectString(expected, actual);
            }
        },
        .@"struct" => |structType| {
            inline for (structType.field_names) |field_name| {
                try expectEqual(@field(expected, field_name), @field(actual, field_name));
            }
            return;
        },
        .optional => {
            if (@typeInfo(@TypeOf(expected)) == .null) {
                return std.testing.expectEqual(null, actual);
            }
            if (actual) |_actual| {
                return expectEqual(expected, _actual);
            }
            return std.testing.expectEqual(expected, null);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);
            try expectEqual(expectedTag, actualTag);

            inline for (@typeInfo(@TypeOf(actual)).@"union".field_names) |field_name| {
                if (std.mem.eql(u8, field_name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, field_name), @field(actual, field_name));
                    return;
                }
            }
            unreachable;
        },
        else => {},
    }
    return std.testing.expectEqual(expected, actual);
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    if (@typeInfo(@TypeOf(expected)) == .null) {
        return std.testing.expectEqual(null, actual);
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .optional => {
            if (actual) |value| {
                return expectDelta(expected, value, delta);
            }
            return std.testing.expectEqual(null, expected);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(expected))) {
        .optional => {
            if (expected) |value| {
                return expectDelta(value, actual, delta);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    var diff = expected - actual;
    if (diff < 0) {
        diff = -diff;
    }
    if (diff <= delta) {
        return;
    }

    print("Expected {} to be within {} of {}. Actual diff: {}", .{ expected, delta, actual, diff });
    return error.NotWithinDelta;
}

fn isStringArray(comptime T: type) bool {
    if (!is(.array)(T) and !isPtrTo(.array)(T)) {
        return false;
    }
    return std.meta.Elem(T) == u8;
}

const TraitFn = fn (type) bool;
pub fn is(comptime id: std.lang.TypeId) TraitFn {
    const Closure = struct {
        fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

fn isPtrTo(comptime id: std.lang.TypeId) TraitFn {
    const Closure = struct {
        fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

fn isSingleItemPtr(comptime T: type) bool {
    if (comptime is(.pointer)(T)) {
        return @typeInfo(T).pointer.size == .one;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}

pub const Random = struct {
    var instance: ?std.Random.DefaultPrng = null;

    pub fn fill(buf: []u8) void {
        var r = random();
        r.bytes(buf);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            io.random(std.mem.asBytes(&seed));
            instance = std.Random.DefaultPrng.init(seed);
            // instance = std.Random.DefaultPrng.init(0);
        }
        return instance.?.random();
    }
};

pub fn expectJson(a: anytype, b: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);

    errdefer {
        const a_json = std.json.Stringify.valueAlloc(aa, a_value, .{ .whitespace = .indent_2 }) catch unreachable;
        const b_json = std.json.Stringify.valueAlloc(aa, b_value, .{ .whitespace = .indent_2 }) catch unreachable;
        std.debug.print("== Expected ==\n{s}\n\n== Actual ==\n{s}", .{ a_json, b_json });
    }

    try expectJsonValue(a_value, b_value);
}

pub fn isEqualJson(a: anytype, b: anytype) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();
    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);
    return isJsonValue(a_value, b_value);
}

fn convertToJson(arena: Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) {
        return value;
    }

    var str: []const u8 = undefined;
    if (T == []u8 or T == []const u8 or comptime isStringArray(T)) {
        str = value;
    } else {
        str = try std.json.Stringify.valueAlloc(arena, value, .{});
    }
    return std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});
}

fn expectJsonValue(a: std.json.Value, b: std.json.Value) !void {
    try expectEqual(@tagName(a), @tagName(b));

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return,
        .bool => try expectEqual(a.bool, b.bool),
        .integer => try expectEqual(a.integer, b.integer),
        .float => try expectEqual(a.float, b.float),
        .number_string => try expectEqual(a.number_string, b.number_string),
        .string => try expectEqual(a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            try expectEqual(a_len, b_len);
            for (a.array.items, b.array.items) |a_item, b_item| {
                try expectJsonValue(a_item, b_item);
            }
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    try expectJsonValue(entry.value_ptr.*, b_item);
                } else {
                    return error.MissingKey;
                }
            }
        },
    }
}

fn isJsonValue(a: std.json.Value, b: std.json.Value) bool {
    if (std.mem.eql(u8, @tagName(a), @tagName(b)) == false) {
        return false;
    }

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            if (a_len != b_len) {
                return false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (isJsonValue(a_item, b_item) == false) {
                    return false;
                }
            }
            return true;
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    if (isJsonValue(entry.value_ptr.*, b_item) == false) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

pub var test_app: *App = undefined;
pub var test_browser: Browser = undefined;
var test_notification: *Notification = undefined;
pub var test_session: *Session = undefined;

const WEB_API_TEST_ROOT = "src/browser/tests/";
const HtmlRunnerOpts = struct {
    timeout_ms: u32 = 2000,
    inject_script: ?[]const u8 = null,
    load_resources: Config.LoadResources = .{
        .worker = true,
        .iframe = true,
    },
    experimental_features: Config.ExperimentalFeatures = .{},
};

// Create a fresh page on `test_session` and return its root frame — for tests
// that just need a frame to build a DOM in. The page lives on the session;
// release it with `defer testing.test_session.closeAllPages()`.
pub fn createFrame() !*Frame {
    return (try test_session.createPage()).frame().?;
}

pub fn waitForFrame() !void {
    var runner = test_session.runner(.{});
    const frame_id = test_session.pages.items[0].frame._frame_id;
    return runner.waitForFrame(frame_id, 2000, .{ .until = .done });
}

pub fn htmlRunner(comptime path: []const u8, opts: HtmlRunnerOpts) !void {
    defer reset();

    var inject_scripts: [1][]const u8 = undefined;
    if (opts.inject_script) |script| {
        inject_scripts[0] = script;
        test_session.inject_scripts = inject_scripts[0..1];
    }
    defer test_session.inject_scripts = &.{};

    test_session.load_resources = opts.load_resources;
    defer test_session.load_resources = .{
        // original defaults, tests expect these to be on
        .worker = true,
        .iframe = true,
    };

    test_session.experimental_features = opts.experimental_features;
    defer test_session.experimental_features = .{};

    const root = try std.fs.path.joinZ(arena_allocator, &.{ WEB_API_TEST_ROOT, path });
    const stat = std.Io.Dir.cwd().statFile(io, root, .{}) catch |err| {
        std.debug.print("Failed to stat file: '{s}'", .{root});
        return err;
    };

    switch (stat.kind) {
        .file => {
            if (@import("root").shouldRun(std.fs.path.basename(root)) == false) {
                return;
            }
            try @import("root").subtest(root);
            try runWebApiTest(root, opts.timeout_ms);
        },
        .directory => {
            var dir = try std.Io.Dir.cwd().openDir(io, root, .{
                .iterate = true,
                .follow_symlinks = false,
                .access_sub_paths = false,
            });
            defer dir.close(io);

            var it = dir.iterateAssumeFirstIteration();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) {
                    continue;
                }

                if (!std.mem.endsWith(u8, entry.name, ".html")) {
                    continue;
                }

                if (@import("root").shouldRun(entry.name) == false) {
                    continue;
                }

                const full_path = try std.fs.path.joinZ(arena_allocator, &.{ root, entry.name });
                try @import("root").subtest(entry.name);
                try runWebApiTest(full_path, opts.timeout_ms);
            }
        },
        else => |kind| {
            std.debug.print("Unknown file type: {s} for {s}\n", .{ @tagName(kind), root });
            return error.InvalidTestPath;
        },
    }
}

fn runWebApiTest(test_file: [:0]const u8, timeout_ms: u32) !void {
    const page = try test_session.createPage();
    defer page.close();

    const url = try arena_allocator.printSentinel(
        "http://127.0.0.1:9582/{s}",
        .{test_file},
        0,
    );

    const frame = page.frame().?;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        try frame.navigate(url, .{});
    }

    var runner = test_session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .load });

    var wait_ms: u32 = timeout_ms;
    var timer: std.Io.Timestamp = .now(lp.io, .boot);
    while (true) {
        const sleep_ms: usize = switch (try runner.tickForFrame(page.frame_id, 20, .{ .until = .done })) {
            .done => @min(test_session.browser.msToNextTask() orelse 20, 20), // could be at BLOCKING_NESTING, so wait a bit more
            .ok => |next_ms| @min(next_ms, 20),
        };

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const js_val = ls.local.exec(
            // testing is undefined until testing.js is run
            "typeof testing === 'undefined' ? false : testing.assertOk()",
            "testing.assertOk()",
        ) catch |err| {
            const caught = try_catch.caughtOrError(arena_allocator, err);
            std.debug.print("{s}: test failure\nError: {f}\n", .{ test_file, caught });
            return err;
        };
        if (js_val.isTrue()) {
            return;
        }

        const lap: std.Io.Timestamp = .now(lp.io, .boot);
        const ms_elapsed: u64 = @intCast(timer.durationTo(lap).toMilliseconds());
        timer = lap;
        if (ms_elapsed >= wait_ms) {
            ls.local.eval("testing.printTimeoutState()", "testing.printTimeoutState()") catch {};
            return error.TestTimedOut;
        }
        wait_ms -= @intCast(ms_elapsed);

        // WebSocket connection doesn't count as pending work, but we much prefer
        // waiting on on activity than a blind sleep.
        const http_client = &test_session.browser.http_client;
        const waited = http_client.activity().ws_conns > 0 and try http_client.tick(@intCast(sleep_ms));
        if (waited == false) {
            lp.io.sleep(.fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
        }
    }
}

const PageTestOpts = struct {
    wait_until_done: bool = true,
};
pub fn pageTest(comptime test_file: []const u8, opts: PageTestOpts) !Session.PageHandle {
    const page = try test_session.createPage();
    errdefer page.close();

    const url = try arena_allocator.printSentinel(
        "http://127.0.0.1:9582/{s}{s}",
        .{ WEB_API_TEST_ROOT, test_file },
        0,
    );

    try page.navigate(url, .{});
    if (opts.wait_until_done) {
        var runner = test_session.runner(.{});
        try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    }
    return page;
}

const Server = @import("server/Server.zig");
const TestWSServer = @import("TestWSServer.zig");
const TestHTTPServer = @import("TestHTTPServer.zig");
const test_routes = @import("test_routes.zig");

pub var test_cdp_server: ?*Server = null;
pub var test_cdp_port: u16 = 0;
var test_cdp_server_thread: ?std.Thread = null;
var test_http_server: ?TestHTTPServer = null;
var test_http_server_thread: ?std.Thread = null;
var test_ws_server: ?TestWSServer = null;
var test_ws_server_thread: ?std.Thread = null;

pub var test_config: Config = undefined;

test "tests:beforeAll" {
    log.opts.level = .warn;
    log.opts.format = .pretty;

    const test_allocator = @import("root").tracking_allocator;

    // Before App.init: its connection pool picks up the routes as it's built.
    {
        var wg: lp.WaitGroup = .{};
        wg.startMany(2);

        test_http_server = TestHTTPServer.init(test_routes.handle, 0);
        test_http_server_thread = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &test_http_server.?, &wg });

        test_ws_server = TestWSServer.init(0);
        test_ws_server_thread = try std.Thread.spawn(.{}, TestWSServer.run, .{ &test_ws_server.?, &wg });

        wg.wait();
        try routeTestPorts();
    }

    test_config = try Config.init(test_allocator, "test", .{
        .serve = .{
            .insecure_disable_tls_host_verification = true,
            .user_agent_suffix = "internal-tester",
            .ws_max_concurrent = 50,
            .load_resources = .{ .worker = true, .iframe = true },
            .watchdog_ms = 0,
        },
    });

    test_app = try App.init(test_allocator, &test_config);
    errdefer test_app.deinit();

    try test_browser.init(test_app, .{});
    errdefer test_browser.deinit();

    // Create notification for testing
    test_notification = try Notification.init(test_app.allocator);
    errdefer test_notification.deinit();

    test_session = try test_browser.newSession(test_notification);

    // need to wait for the server to be listening, else tests will fail because
    // they aren't able to connect.
    var wg: lp.WaitGroup = .{};
    wg.start();
    test_cdp_server_thread = try std.Thread.spawn(.{}, serveCDP, .{&wg});
    wg.wait();
}

/// Fixtures address the test servers by fixed ports, but each test process
/// binds ephemeral ones so that several can run at once.
fn routeTestPorts() !void {
    const routes = [_]struct { u16, u16 }{
        .{ 9582, test_http_server.?.listener.?.socket.address.getPort() },
        .{ 9584, test_ws_server.?.port },
    };

    var list: ?*libcurl.CurlSList = null;
    errdefer libcurl.curl_slist_free_all(list);
    for (routes) |route| {
        const port, const real_port = route;
        // an empty host matches any, so both 127.0.0.1 and localhost
        const entry = try arena_allocator.printSentinel(":{d}:127.0.0.1:{d}", .{ port, real_port }, 0);
        list = libcurl.curl_slist_append(list, entry) orelse return error.OutOfMemory;
    }
    http.test_connect_to = list;
}

test "tests:afterAll" {
    if (test_cdp_server) |server| {
        server.shutdown();
    }
    if (test_cdp_server_thread) |thread| {
        thread.join();
    }
    if (test_cdp_server) |server| {
        server.deinit();
    }

    if (test_http_server) |*server| {
        server.stop();
    }
    if (test_http_server_thread) |thread| {
        thread.join();
    }
    if (test_http_server) |*server| {
        server.deinit();
    }

    if (test_ws_server) |*server| {
        server.stop();
    }
    if (test_ws_server_thread) |thread| {
        thread.join();
    }

    @import("root").v8_peak_memory = test_browser.env.isolate.getHeapStatistics().total_physical_size;

    // Browser must be deinit'd before the notification — Session/Frame
    // teardown may unregister notification listeners (e.g. CookieStore
    // detach), which dereferences `notification.listeners`.
    test_browser.deinit();
    test_notification.deinit();
    test_app.deinit();
    // curl keeps the list, not a copy: free it once no handle is left
    libcurl.curl_slist_free_all(http.test_connect_to);
    http.test_connect_to = null;
    test_config.deinit(@import("root").tracking_allocator);
}

fn serveCDP(wg: *lp.WaitGroup) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);

    test_cdp_server = Server.init(test_app, .{ .ip = address }) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };

    test_cdp_port = (try sys_net.boundAddress(test_cdp_server.?.listener)).getPort();
    test_cdp_server.?.protocols = .{ .cdp = true, .webdriver = true };
    wg.finish();

    test_cdp_server.?.run();
}

/// Declares the log lines a test expects to emit: one entry per line, so
/// `&.{ .js, .js, .http }` covers two `js` lines and one `http` line.
pub const expectLog = log.expectLog;

/// Suppresses every line from `scopes` for the rest of the test.
pub fn silenceLog(comptime scopes: []const log.Scope) void {
    inline for (scopes) |scope| {
        log.opts.scope_enabled[@backingInt(scope)] = false;
    }
}

test "tests:afterEach" {
    defer reset();
    const unmet = log.resetTestState();
    if (@import("root").hasSubfilter()) {
        // only part of the test ran, so expectations about what it logs
        // don't hold.
        return;
    }

    var failed = false;
    for (unmet, 0..) |count, i| {
        if (count == 0) {
            continue;
        }
        failed = true;
        const scope: log.Scope = @fromBackingInt(@intCast(i));
        std.debug.print("expected {d} more {s} log line(s)\n", .{ count, @tagName(scope) });
    }

    if (failed) {
        return error.UnmetLogExpectation;
    }
}

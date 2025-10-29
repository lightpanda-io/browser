// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;

pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expect = std.testing.expect;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;

// sometimes it's super useful to have an arena you don't really care about
// in a test. Like, you need a mutable string, so you just want to dupe a
// string literal. It has nothing to do with the code under test, it's just
// infrastructure for the test itself.
pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.c_allocator);
pub const arena_allocator = arena_instance.allocator();

pub fn reset() void {
    _ = arena_instance.reset(.retain_capacity);
}

const App = @import("App.zig");
const js = @import("browser/js/js.zig");
const Browser = @import("browser/Browser.zig");
const Session = @import("browser/Session.zig");

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
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
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

            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
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

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
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

    pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
        var r = random();
        const l = r.intRangeAtMost(usize, min, buf.len);
        r.bytes(buf[0..l]);
        return buf;
    }

    pub fn intRange(comptime T: type, min: T, max: T) T {
        var r = random();
        return r.intRangeAtMost(T, min, max);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
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

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
pub var test_app: *App = undefined;
pub var test_browser: Browser = undefined;
pub var test_session: *Session = undefined;

const WEB_API_TEST_ROOT = "src/browser/tests/";
const WEB_API_HELPER_PATH = WEB_API_TEST_ROOT ++ "testing.js";
const HtmlRunnerOpts = struct {};

pub fn htmlRunner(comptime path: []const u8, opts: HtmlRunnerOpts) !void {
    _ = opts;
    defer reset();

    const root = try std.fs.path.joinZ(arena_allocator, &.{ WEB_API_TEST_ROOT, path });
    const stat = std.fs.cwd().statFile(root) catch |err| {
        std.debug.print("Failed to stat file: '{s}'", .{root});
        return err;
    };

    switch (stat.kind) {
        .file => {
            if (@import("root").shouldRun(std.fs.path.basename(root)) == false) {
                return;
            }
            try @import("root").subtest(root);
            try runWebApiTest(root);
        },
        .directory => {
            var dir = try std.fs.cwd().openDir(root, .{
                .iterate = true,
                .no_follow = true,
                .access_sub_paths = false,
            });
            defer dir.close();

            var it = dir.iterateAssumeFirstIteration();
            while (try it.next()) |entry| {
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
                try runWebApiTest(full_path);
            }
        },
        else => |kind| {
            std.debug.print("Unknown file type: {s} for {s}\n", .{ @tagName(kind), root });
            return error.InvalidTestPath;
        },
    }
}

fn runWebApiTest(test_file: [:0]const u8) !void {
    const page = try test_session.createPage();
    defer test_session.removePage();

    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}",
        .{test_file},
        0,
    );

    const js_context = page.js;
    var try_catch: js.TryCatch = undefined;
    try_catch.init(js_context);
    defer try_catch.deinit();

    try page.navigate(url, .{});
    test_session.fetchWait(2000);

    page._session.browser.runMicrotasks();
    page._session.browser.runMessageLoop();

    js_context.eval("testing.assertOk()", "testing.assertOk()") catch |err| {
        const msg = try_catch.err(arena_allocator) catch @errorName(err) orelse "unknown";
        std.debug.print("{s}: test failure\nError: {s}\n", .{ test_file, msg });
        return err;
    };
}

test {
    std.testing.refAllDecls(@This());
}

const log = @import("log.zig");
const TestHTTPServer = @import("TestHTTPServer.zig");

const Server = @import("Server.zig");
var test_cdp_server: ?Server = null;
var test_http_server: ?TestHTTPServer = null;

test "tests:beforeAll" {
    log.opts.level = .warn;
    log.opts.format = .pretty;

    test_app = try App.init(gpa.allocator(), .{
        .run_mode = .serve,
        .tls_verify_host = false,
        .user_agent = "User-Agent: Lightpanda/1.0 internal-tester",
    });
    errdefer test_app.deinit();

    test_browser = try Browser.init(test_app);
    errdefer test_browser.deinit();

    test_session = try test_browser.newSession();

    var wg: std.Thread.WaitGroup = .{};
    wg.startMany(2);

    {
        const thread = try std.Thread.spawn(.{}, serveCDP, .{&wg});
        thread.detach();
    }

    test_http_server = TestHTTPServer.init(testHTTPHandler);
    {
        const thread = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &test_http_server.?, &wg });
        thread.detach();
    }

    // need to wait for the servers to be listening, else tests will fail because
    // they aren't able to connect.
    wg.wait();
}

test "tests:afterAll" {
    if (test_cdp_server) |*server| {
        server.deinit();
    }
    if (test_http_server) |*server| {
        server.deinit();
    }

    test_browser.deinit();
    test_app.deinit();
}

fn serveCDP(wg: *std.Thread.WaitGroup) !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 9583);
    test_cdp_server = try Server.init(test_app, address);

    var server = try Server.init(test_app, address);
    defer server.deinit();
    wg.finish();

    test_cdp_server.?.run(address, 5) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
}

fn testHTTPHandler(req: *std.http.Server.Request) !void {
    const path = req.head.target;

    if (std.mem.eql(u8, path, "/loader")) {
        return req.respond("Hello!", .{
            .extra_headers = &.{.{ .name = "Connection", .value = "close" }},
        });
    }

    if (std.mem.eql(u8, path, "/xhr")) {
        return req.respond("1234567890" ** 10, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/json")) {
        return req.respond("{\"over\":\"9000!!!\"}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/src/browser/tests/")) {
        // strip off leading / so that it's relative to CWD
        return TestHTTPServer.sendFile(req, path[1..]);
    }

    std.debug.print("TestHTTPServer was asked to serve an unknown file: {s}\n", .{path});

    unreachable;
}

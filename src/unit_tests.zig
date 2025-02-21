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
const builtin = @import("builtin");
const parser = @import("netsurf");

const Allocator = std.mem.Allocator;

const jsruntime = @import("jsruntime");
pub const Types = jsruntime.reflect(@import("generate.zig").Tuple(.{}){});
pub const UserContext = @import("user_context.zig").UserContext;
// pub const IO = @import("asyncio").Wrapper(jsruntime.Loop);

pub const std_options = std.Options{
    .log_level = .err,
    .http_disable_tls = true,
};

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    try parser.init();
    defer parser.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var loop = try jsruntime.Loop.init(allocator);
    defer loop.deinit();

    const env = Env.init(allocator);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    const http_thread = blk: {
        const address = try std.net.Address.parseIp("127.0.0.1", 9582);
        const thread = try std.Thread.spawn(.{}, serveHTTP, .{address});
        break :blk thread;
    };
    defer http_thread.join();

    const cdp_thread = blk: {
        const address = try std.net.Address.parseIp("127.0.0.1", 9583);
        const thread = try std.Thread.spawn(.{}, serveCDP, .{ allocator, address, &loop });
        break :blk thread;
    };
    defer cdp_thread.join();

    const printer = Printer.init();
    printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, "unit_tests.test_0")) {
            // don't display anything for this test
            try t.func();
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .{};
        const result = t.func();
        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name, is_unnamed_test);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            if (is_unnamed_test == false) {
                pass += 1;
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }

        if (is_unnamed_test == false) {
            if (env.verbose) {
                const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
            } else {
                printer.status(status, ".", .{});
            }
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    printer.fmt("\n", .{});
    try slowest.display(printer);
    printer.fmt("\n", .{});
    std.posix.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    out: std.fs.File.Writer,

    fn init() Printer {
        return .{
            .out = std.io.getStdErr().writer(),
        };
    }

    fn fmt(self: Printer, comptime format: []const u8, args: anytype) void {
        std.fmt.format(self.out, format, args) catch unreachable;
    }

    fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) void {
        const color = switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        };
        const out = self.out;
        out.writeAll(color) catch @panic("writeAll failed?!");
        std.fmt.format(out, format, args) catch @panic("std.fmt.format failed?!");
        self.fmt("\x1b[0m", .{});
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.time.Timer,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        const timer = std.time.Timer.start() catch @panic("failed to start timer");
        var slowest = SlowestQueue.init(allocator, {});
        slowest.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = timer,
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8, is_unnamed_test: bool) u64 {
        var timer = self.timer;
        const ns = timer.lap();
        if (is_unnamed_test) {
            return ns;
        }

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.removeMin();
        slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker, printer: Printer) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(allocator: Allocator) Env {
        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .filter = readEnv(allocator, "TEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn serveHTTP(address: std.net.Address) !void {
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    var read_buffer: [1024]u8 = undefined;
    ACCEPT: while (true) {
        var conn = try listener.accept();
        defer conn.stream.close();
        var server = std.http.Server.init(conn, &read_buffer);

        while (server.state == .ready) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :ACCEPT,
                else => {
                    std.debug.print("Test HTTP Server error: {}\n", .{err});
                    return err;
                },
            };

            const path = request.head.target;
            if (std.mem.eql(u8, path, "/loader")) {
                try writeResponse(&request, .{
                    .body = "Hello!",
                });
            }
        }
    }
}

fn serveCDP(allocator: Allocator, address: std.net.Address, loop: *jsruntime.Loop) !void {
    const server = @import("server.zig");
    server.run(allocator, address, std.time.ns_per_s * 2, loop) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
}

const Response = struct {
    body: []const u8 = "",
    status: std.http.Status = .ok,
};

fn writeResponse(req: *std.http.Server.Request, res: Response) !void {
    try req.respond(res.body, .{ .status = res.status });
}

test {
    std.testing.refAllDecls(@import("url/query.zig"));
    std.testing.refAllDecls(@import("browser/dump.zig"));
    std.testing.refAllDecls(@import("browser/loader.zig"));
    std.testing.refAllDecls(@import("browser/mime.zig"));
    std.testing.refAllDecls(@import("css/css.zig"));
    std.testing.refAllDecls(@import("css/libdom_test.zig"));
    std.testing.refAllDecls(@import("css/match_test.zig"));
    std.testing.refAllDecls(@import("css/parser.zig"));
    std.testing.refAllDecls(@import("generate.zig"));
    std.testing.refAllDecls(@import("http/Client.zig"));
    std.testing.refAllDecls(@import("storage/storage.zig"));
    std.testing.refAllDecls(@import("iterator/iterator.zig"));
    std.testing.refAllDecls(@import("server.zig"));
    std.testing.refAllDecls(@import("cdp/cdp.zig"));
}

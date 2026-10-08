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
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const BORDER: [80]u8 = @splat('=');

// use in custom panic handler
var current_test: ?[]const u8 = null;
pub var v8_peak_memory: usize = 0;
pub var tracking_allocator: Allocator = undefined;

var RUNNER: *Runner = undefined;

pub fn main(init: std.process.Init) !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var ta = TrackingAllocator.init(gpa.allocator());
    tracking_allocator = ta.allocator();

    const allocator = fba.allocator();

    std.testing.io_instance = .init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer std.testing.io_instance.deinit();

    const env = Env.init(init.environ_map);
    if (env.shard == null and env.jobs > 1) {
        try runShards(std.testing.io_instance.io(), arena.allocator(), init.environ_map, env.jobs);
    }

    var runner = Runner.init(allocator, arena.allocator(), &ta, env);
    RUNNER = &runner;
    try runner.run(std.testing.io_instance.io());
}

const Runner = struct {
    env: Env,
    allocator: Allocator,
    ta: *TrackingAllocator,

    // per-test arena, used for collecting substests
    arena: Allocator,
    subtests: std.ArrayList([]const u8),

    fn init(allocator: Allocator, arena: Allocator, ta: *TrackingAllocator, env: Env) Runner {
        return .{
            .ta = ta,
            .env = env,
            .arena = arena,
            .subtests = .empty,
            .allocator = allocator,
        };
    }

    pub fn run(self: *Runner, io: Io) !void {
        var slowest = SlowTracker.init(io, self.allocator, 5);
        defer slowest.deinit();

        var fail_list: std.ArrayList([]const u8) = .empty;

        var pass: usize = 0;
        var fail: usize = 0;
        var skip: usize = 0;
        var leak: usize = 0;
        // track all tests duration, excluding setup and teardown.
        var ns_duration: u64 = 0;

        Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

        var after_each: ?std.lang.TestFn = null;
        for (builtin.test_functions) |t| {
            if (isAfterEach(t)) {
                after_each = t;
            }
            if (isSetup(t)) {
                t.func() catch |err| {
                    Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                    return err;
                };
            }
        }

        // If we have a subfilter, Document#query_selector_all
        // Then we have a special check to make sure _some_ test was run. This
        const webapi_html_test_mode = self.env.filter == null and self.env.subfilter != null;

        var index: usize = 0;
        for (builtin.test_functions) |t| {
            if (isSetup(t) or isTeardown(t) or isAfterEach(t)) {
                continue;
            }

            if (self.env.shard) |shard| {
                defer index += 1;
                if (index % shard.count != shard.index) {
                    continue;
                }
            }

            var status = Status.pass;
            slowest.startTiming(io);

            const is_unnamed_test = isUnnamed(t);
            if (!is_unnamed_test) {
                if (self.env.filter) |f| {
                    if (std.mem.find(u8, t.name, f) == null) {
                        continue;
                    }
                } else if (webapi_html_test_mode) {
                    // allow filtering by subfilter only, assumes subfilters
                    // only exists for "WebApi: " tests (which is true for now).
                    if (std.mem.find(u8, t.name, "WebApi: ") == null) {
                        continue;
                    }
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
            defer {
                self.subtests = .empty;
                const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
                _ = arena.reset(.{ .retain_with_limit = 2048 });
            }

            current_test = friendly_name;
            std.testing.allocator_instance = .init(std.heap.page_allocator, .{
                .canary = 0xc3a701ba,
                .check_write_after_free = true,
            });
            var result = t.func();
            if (after_each) |ae| {
                // always runs, so that it can reset state, but it can only
                // turn a passing test into a failing one.
                ae.func() catch |err| {
                    if (result) |_| {
                        result = err;
                    } else |_| {}
                };
            }
            current_test = null;

            if (webapi_html_test_mode and self.subtests.items.len == 0) {
                continue;
            }

            const ns_taken = slowest.endTiming(io, friendly_name, is_unnamed_test);
            ns_duration += ns_taken;

            if (std.testing.allocator_instance.deinit() != 0) {
                leak += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
            }

            if (result) |_| {
                if (!is_unnamed_test) {
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
                    Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n", .{ BORDER, friendly_name, @errorName(err) });
                    if (self.subtests.last()) |st| {
                        Printer.status(.fail, " {s}\n", .{st});
                    }
                    Printer.status(.fail, BORDER ++ "\n", .{});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpErrorReturnTrace(trace);
                    }
                    if (self.env.fail_first) {
                        break;
                    }
                    try fail_list.append(self.allocator, try self.allocator.dupe(u8, friendly_name));
                },
            }

            if (!is_unnamed_test) {
                if (self.env.verbose) {
                    const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                    Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
                    for (self.subtests.items) |st| {
                        Printer.status(status, "  - {s} \n", .{st});
                    }
                } else {
                    Printer.status(status, ".", .{});
                }
            }
        }

        for (builtin.test_functions) |t| {
            if (isTeardown(t)) {
                t.func() catch |err| {
                    Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                    return err;
                };
            }
        }

        const report: Report = .{
            .pass = pass,
            .fail = fail,
            .skip = skip,
            .leak = leak,
            .failed = fail_list.items,
            .slowest = slowest.drain(self.arena),
        };

        if (self.env.report) |path| {
            const json = try std.json.Stringify.valueAlloc(self.arena, report, .{});
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
        } else {
            try self.printReport(io, report, ns_duration);
        }

        std.process.exit(if (fail == 0) 0 else 1);
    }

    fn printReport(self: *Runner, io: Io, report: Report, ns_duration: u64) !void {
        report.print();
        // stats
        if (self.env.metrics) {
            Printer.fmt("\n", .{});
            const stdout = std.Io.File.stdout();
            var writer = stdout.writerStreaming(io, &.{});
            const stats = self.ta.stats();
            try std.json.Stringify.value(&.{
                .{ .name = "browser", .bench = .{
                    .duration = ns_duration,
                    .alloc_nb = stats.allocation_count,
                    .realloc_nb = stats.reallocation_count,
                    .alloc_size = stats.allocated_bytes,
                } },
                .{ .name = "v8", .bench = .{
                    .duration = ns_duration,
                    .alloc_nb = 0,
                    .realloc_nb = 0,
                    .alloc_size = v8_peak_memory,
                } },
            }, .{ .whitespace = .indent_2 }, &writer.interface);
            Printer.fmt("\n", .{});
        }

        report.printFailed();
    }
};

// A run's outcome. Shards send it to their parent as JSON.
const Report = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    leak: usize = 0,
    failed: []const []const u8 = &.{},
    slowest: []const SlowTracker.TestInfo = &.{},

    fn print(self: *const Report) void {
        const total_tests = self.pass + self.fail;
        const status = if (total_tests > 0 and self.fail == 0) Status.pass else Status.fail;
        Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ self.pass, total_tests, if (total_tests != 1) "s" else "" });
        if (self.skip > 0) {
            Printer.status(.skip, "{d} test{s} skipped\n", .{ self.skip, if (self.skip != 1) "s" else "" });
        }
        if (self.leak > 0) {
            Printer.status(.fail, "{d} test{s} leaked\n", .{ self.leak, if (self.leak != 1) "s" else "" });
        }
        if (self.slowest.len > 0) {
            Printer.fmt("\nSlowest {d} test{s}: \n", .{ self.slowest.len, if (self.slowest.len != 1) "s" else "" });
            for (self.slowest) |info| {
                const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
                Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
            }
        }
    }

    fn printFailed(self: *const Report) void {
        if (self.failed.len > 0) {
            Printer.status(.fail, "\nFailed Test Summary: \n", .{});
            for (self.failed) |name| {
                Printer.status(.fail, "- {s}\n", .{name});
            }
        }
    }
};

/// Runs the suite as `jobs` copies of this binary, each taking every jobs-th
/// test, and merges what they report.
fn runShards(io: Io, arena: Allocator, environ_map: *const std.process.Environ.Map, jobs: usize) !noreturn {
    const exe = try std.process.executablePathAlloc(io, arena);
    const dir = try arena.print(".zig-cache/tmp/test-shards-{d}", .{std.c.getpid()});
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const children = try arena.alloc(std.process.Child, jobs);
    const report_paths = try arena.alloc([]const u8, jobs);
    for (children, report_paths, 0..) |*child, *report_path, i| {
        report_path.* = try arena.print("{s}/{d}.json", .{ dir, i });
        var child_env = try environ_map.clone(arena);
        try child_env.put("TEST_SHARD", try arena.print("{d}/{d}", .{ i, jobs }));
        try child_env.put("TEST_REPORT", report_path.*);
        child.* = try std.process.spawn(io, .{ .argv = &.{exe}, .environ_map = &child_env });
    }

    var total: Report = .{};
    var failed: std.ArrayList([]const u8) = .empty;
    var slowest: SlowTracker = .init(io, arena, 5);
    var crashed = false;
    for (children, report_paths, 0..) |*child, report_path, i| {
        const term = try child.wait(io);
        const data = Io.Dir.cwd().readFileAlloc(io, report_path, arena, .limited(1024 * 1024)) catch {
            Printer.status(.fail, "\nshard {d}/{d} exited without a report: {any}\n", .{ i, jobs, term });
            crashed = true;
            continue;
        };
        const report = try std.json.parseFromSliceLeaky(Report, arena, data, .{});
        total.pass += report.pass;
        total.fail += report.fail;
        total.skip += report.skip;
        total.leak += report.leak;
        try failed.appendSlice(arena, report.failed);
        for (report.slowest) |info| {
            slowest.track(info.name, info.ns);
        }
    }
    total.failed = failed.items;
    total.slowest = slowest.drain(arena);

    total.print();
    total.printFailed();
    std.process.exit(if (total.fail == 0 and !crashed) 0 else 1);
}

// When only part of a test runs, expectations about what the whole test logs
// can't be enforced.
pub fn hasSubfilter() bool {
    return RUNNER.env.subfilter != null;
}

pub fn shouldRun(name: []const u8) bool {
    const sf = RUNNER.env.subfilter orelse return true;
    return std.mem.find(u8, name, sf) != null;
}

pub fn subtest(name: []const u8) !void {
    try RUNNER.subtests.append(RUNNER.arena, try RUNNER.arena.dupe(u8, name));
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        // Reset before a trailing newline so the escape never starts the next line.
        const reset = "\x1b[0m";
        if (comptime std.mem.endsWith(u8, format, "\n")) {
            std.debug.print(format[0 .. format.len - 1] ++ reset ++ "\n", args);
        } else {
            std.debug.print(format ++ reset, args);
        }
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    max: usize,
    slowest: SlowestQueue,
    start: Io.Timestamp,
    allocator: Allocator,

    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);

    fn init(io: Io, allocator: Allocator, count: u32) SlowTracker {
        const start = Io.Clock.awake.now(io);
        var slowest = SlowestQueue.initContext({});
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .max = count,
            .start = start,
            .slowest = slowest,
            .allocator = allocator,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker) void {
        self.slowest.deinit(self.allocator);
    }

    fn startTiming(self: *SlowTracker, io: Io) void {
        self.start = Io.Clock.awake.now(io);
    }

    fn endTiming(self: *SlowTracker, io: Io, test_name: []const u8, is_unnamed_test: bool) u64 {
        const timestamp = Io.Clock.awake.now(io);
        const start = self.start;
        self.start = timestamp;
        const ns: u64 = @intCast(start.durationTo(timestamp).toNanoseconds());
        if (!is_unnamed_test) {
            self.track(test_name, ns);
        }
        return ns;
    }

    fn track(self: *SlowTracker, test_name: []const u8, ns: u64) void {
        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin();
        slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
    }

    /// Empties the tracker into a slice, fastest first.
    fn drain(self: *SlowTracker, allocator: Allocator) []const TestInfo {
        const out = allocator.alloc(TestInfo, self.slowest.count()) catch @panic("OOM");
        for (out) |*info| {
            info.* = self.slowest.popMin().?;
        }
        return out;
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
    subfilter: ?[]const u8,
    metrics: bool,
    // number of processes to split the suite across
    jobs: usize,
    // set in a process spawned to run one share of the suite
    shard: ?Shard,
    // where a shard writes its Report
    report: ?[]const u8,

    const Shard = struct {
        index: usize,
        count: usize,
    };

    fn init(map: *const std.process.Environ.Map) Env {
        const full_filter = readEnv(map, "TEST_FILTER");
        const filter, const subfilter = parseFilter(full_filter);
        const metrics = readEnvBool(map, "METRICS", false);

        return .{
            .filter = filter,
            .subfilter = subfilter,
            .metrics = metrics,
            .verbose = readEnvBool(map, "TEST_VERBOSE", false),
            .fail_first = readEnvBool(map, "TEST_FAIL_FIRST", false),
            // metrics are compared across runs, so keep them to one process
            .jobs = if (metrics) 1 else readEnvInt(map, "TEST_JOBS") orelse defaultJobs(),
            .shard = parseShard(readEnv(map, "TEST_SHARD")),
            .report = readEnv(map, "TEST_REPORT"),
        };
    }

    fn defaultJobs() usize {
        const cpus = std.Thread.getCpuCount() catch 1;
        return @min(cpus, 4);
    }

    fn readEnvInt(map: *const std.process.Environ.Map, key: []const u8) ?usize {
        const value = readEnv(map, key) orelse return null;
        return std.fmt.parseInt(usize, value, 10) catch null;
    }

    fn parseShard(value: ?[]const u8) ?Shard {
        const v = value orelse return null;
        const index_str, const count_str = std.mem.cutScalar(u8, v, '/') orelse return null;
        const index = std.fmt.parseInt(usize, index_str, 10) catch return null;
        const count = std.fmt.parseInt(usize, count_str, 10) catch return null;
        if (index >= count) return null;
        return .{ .index = index, .count = count };
    }

    fn readEnv(map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
        return map.get(key);
    }

    fn readEnvBool(map: *const std.process.Environ.Map, key: []const u8, deflt: bool) bool {
        const value = readEnv(map, key) orelse return deflt;
        return std.ascii.eqlIgnoreCase(value, "true");
    }

    fn parseFilter(full_filter: ?[]const u8) struct { ?[]const u8, ?[]const u8 } {
        const ff = full_filter orelse return .{ null, null };
        if (ff.len == 0) return .{ null, null };

        const split = std.mem.findScalarPos(u8, ff, 0, '#') orelse {
            return .{ ff, null };
        };

        const filter = std.mem.trim(u8, ff[0..split], " ");

        return .{
            if (filter.len == 0) null else filter,
            std.mem.trim(u8, ff[split + 1 ..], " "),
        };
    }
};

pub const panic = std.debug.FullPanic(struct {
    fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n", .{ BORDER, ct });
            if (RUNNER.subtests.last()) |st| {
                std.debug.print(" {s}\n", .{st});
            }
            std.debug.print("\x1b[0m{s}\n", .{BORDER});
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.lang.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.find(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.lang.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.lang.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}

fn isAfterEach(t: std.lang.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterEach");
}

const TrackingAllocator = struct {
    parent_allocator: Allocator,
    free_count: usize = 0,
    allocated_bytes: usize = 0,
    allocation_count: usize = 0,
    reallocation_count: usize = 0,
    mutex: std.Io.Mutex = .init,

    const Stats = struct {
        allocated_bytes: usize,
        allocation_count: usize,
        reallocation_count: usize,
    };

    fn init(parent_allocator: Allocator) TrackingAllocator {
        return .{
            .parent_allocator = parent_allocator,
        };
    }

    pub fn stats(self: *const TrackingAllocator) Stats {
        return .{
            .allocated_bytes = self.allocated_bytes,
            .allocation_count = self.allocation_count,
            .reallocation_count = self.reallocation_count,
        };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        } };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);

        const result = self.parent_allocator.rawAlloc(len, alignment, return_address);
        self.allocation_count += 1;
        self.allocated_bytes += len;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);

        const result = self.parent_allocator.rawResize(old_mem, alignment, new_len, ra);
        if (result) self.reallocation_count += 1;
        return result;
    }

    fn free(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);

        self.parent_allocator.rawFree(old_mem, alignment, ra);
        self.free_count += 1;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);

        const result = self.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) self.reallocation_count += 1;
        return result;
    }
};

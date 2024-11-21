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

const jsruntime = @import("jsruntime");

const Suite = @import("wpt/testcase.zig").Suite;
const FileLoader = @import("wpt/fileloader.zig").FileLoader;
const wpt = @import("wpt/run.zig");

const apiweb = @import("apiweb.zig");
const HTMLElem = @import("html/elements.zig");

const wpt_dir = "tests/wpt";

const usage =
    \\usage: {s} [options] [test filter]
    \\  Run the Web Test Platform.
    \\
    \\  -h, --help       Print this help message and exit.
    \\  --json           result is formatted in JSON.
    \\  --safe           each test is run in a separate process.
    \\  --summary        print a summary result. Incompatible w/ --json
    \\
;

// Out list all the ouputs handled by WPT.
const Out = enum {
    json,
    summary,
    text,
};

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const GlobalType = apiweb.GlobalType;
pub const UserContext = apiweb.UserContext;
pub const IO = @import("asyncio").Wrapper(jsruntime.Loop);

// TODO For now the WPT tests run is specific to WPT.
// It manually load js framwork libs, and run the first script w/ js content in
// the HTML page.
// Once lightpanda will have the html loader, it would be useful to refacto
// this test to use it.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // get the exec name.
    const execname = args.next().?;

    var out: Out = .text;
    var safe = false;

    var filter = std.ArrayList([]const u8).init(alloc);
    defer filter.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.io.getStdErr().writer().print(usage, .{execname});
            std.posix.exit(0);
        }
        if (std.mem.eql(u8, "--json", arg)) {
            out = .json;
            continue;
        }
        if (std.mem.eql(u8, "--safe", arg)) {
            safe = true;
            continue;
        }
        if (std.mem.eql(u8, "--summary", arg)) {
            out = .summary;
            continue;
        }
        try filter.append(arg[0..]);
    }

    // summary is available in safe mode only.
    if (out == .summary) {
        safe = true;
    }

    // browse the dir to get the tests dynamically.
    var list = std.ArrayList([]const u8).init(alloc);
    try wpt.find(alloc, wpt_dir, &list);
    defer {
        for (list.items) |tc| {
            alloc.free(tc);
        }
        list.deinit();
    }

    if (safe) {
        return try runSafe(alloc, execname, out, list.items, filter.items);
    }

    var results = std.ArrayList(Suite).init(alloc);
    defer {
        for (results.items) |suite| {
            suite.deinit();
        }
        results.deinit();
    }

    // initialize VM JS lib.
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // prepare libraries to load on each test case.
    var loader = FileLoader.init(alloc, wpt_dir);
    defer loader.deinit();

    var run: usize = 0;
    var failures: usize = 0;
    for (list.items) |tc| {
        if (!shouldRun(filter.items, tc)) {
            continue;
        }

        run += 1;

        // create an arena and deinit it for each test case.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const res = wpt.run(&arena, wpt_dir, tc, &loader) catch |err| {
            const suite = try Suite.init(alloc, tc, false, @errorName(err));
            try results.append(suite);

            if (out == .text) {
                std.debug.print("FAIL\t{s}\t{}\n", .{ tc, err });
            }
            failures += 1;
            continue;
        };
        defer res.deinit(arena.allocator());

        const suite = try Suite.init(alloc, tc, res.ok, res.msg orelse "");
        try results.append(suite);

        if (out == .json) {
            continue;
        }

        if (!suite.pass) {
            std.debug.print("Fail\t{s}\n{s}\n", .{ suite.name, suite.fmtMessage() });
            failures += 1;
        } else {
            std.debug.print("Pass\t{s}\n", .{suite.name});
        }

        // display details
        if (suite.cases) |cases| {
            for (cases) |case| {
                std.debug.print("\t{s}\t{s}\t{s}\n", .{ case.fmtStatus(), case.name, case.fmtMessage() });
            }
        }
    }

    if (out == .json) {
        var output = std.ArrayList(Test).init(alloc);
        defer output.deinit();

        for (results.items) |suite| {
            var cases = std.ArrayList(Case).init(alloc);
            defer cases.deinit();

            if (suite.cases) |scases| {
                for (scases) |case| {
                    try cases.append(Case{
                        .pass = case.pass,
                        .name = case.name,
                        .message = case.message,
                    });
                }
            } else {
                // no cases, generate a fake one
                try cases.append(Case{
                    .pass = suite.pass,
                    .name = suite.name,
                    .message = suite.message,
                });
            }

            try output.append(Test{
                .pass = suite.pass,
                .name = suite.name,
                .cases = try cases.toOwnedSlice(),
            });
        }

        defer {
            for (output.items) |suite| {
                alloc.free(suite.cases);
            }
        }

        try std.json.stringify(output.items, .{ .whitespace = .indent_2 }, std.io.getStdOut().writer());
        std.posix.exit(0);
    }

    if (out == .text and failures > 0) {
        std.debug.print("{d}/{d} tests suites failures\n", .{ failures, run });
        std.posix.exit(1);
    }
}

// struct used for JSON output.
const Case = struct {
    pass: bool,
    name: []const u8,
    message: ?[]const u8,
};
const Test = struct {
    pass: bool,
    crash: bool = false,
    name: []const u8,
    cases: []Case,
};

// shouldRun return true if the test should be run accroding to the given filters.
fn shouldRun(filter: [][]const u8, tc: []const u8) bool {
    if (filter.len == 0) {
        return true;
    }

    for (filter) |f| {
        if (std.mem.startsWith(u8, tc, f)) {
            return true;
        }
        if (std.mem.endsWith(u8, tc, f)) {
            return true;
        }
    }
    return false;
}

// runSafe rune each test cae in a separate child process to detect crashes.
fn runSafe(
    allocator: std.mem.Allocator,
    execname: []const u8,
    out: Out,
    testcases: [][]const u8,
    filter: [][]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const Result = enum {
        success,
        crash,
    };

    var argv = try std.ArrayList([]const u8).initCapacity(alloc, 3);
    defer argv.deinit();
    argv.appendAssumeCapacity(execname);
    // always require json output to count test cases results
    argv.appendAssumeCapacity("--json");

    var output = std.ArrayList(Test).init(alloc);

    for (testcases) |tc| {
        if (!shouldRun(filter, tc)) {
            continue;
        }

        // append the test case to argv and pop it before next loop.
        argv.appendAssumeCapacity(tc);
        defer _ = argv.pop();

        const run = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = argv.items,
            .max_output_bytes = 1024 * 1024,
        });

        const result: Result = switch (run.term) {
            .Exited => .success,
            else => .crash,
        };

        // read the JSON result from stdout
        var tests: []Test = undefined;
        if (result != .crash) {
            const parsed = try std.json.parseFromSlice([]Test, alloc, run.stdout, .{});
            tests = parsed.value;
        }

        // summary display
        if (out == .summary) {
            defer std.debug.print("\t{s}\n", .{tc});
            if (result == .crash) {
                std.debug.print("Crash\t", .{});
                continue;
            }

            // count results
            var pass: u32 = 0;
            var all: u32 = 0;
            for (tests) |ttc| {
                for (ttc.cases) |c| {
                    all += 1;
                    if (c.pass) pass += 1;
                }
            }
            const status = if (all > 0 and pass == all) "Pass" else "Fail";
            std.debug.print("{s} {d}/{d}", .{ status, pass, all });

            continue;
        }

        // json display
        if (out == .json) {
            if (result == .crash) {
                var cases = [_]Case{.{
                    .pass = false,
                    .name = "crash",
                    .message = run.stderr,
                }};
                try output.append(Test{
                    .pass = false,
                    .crash = true,
                    .name = tc,
                    .cases = cases[0..1],
                });
                continue;
            }

            try output.appendSlice(tests);
            continue;
        }

        // normal display
        std.debug.print("{s}\n", .{tc});
        if (result == .crash) {
            std.debug.print("Crash\n{s}", .{run.stderr});
            continue;
        }
        var pass: u32 = 0;
        var all: u32 = 0;
        for (tests) |ttc| {
            for (ttc.cases) |c| {
                const status = if (c.pass) "Pass" else "Fail";
                std.debug.print("{s}\t{s}\n", .{ status, c.name });
                all += 1;
                if (c.pass) pass += 1;
            }
        }
        const status = if (all > 0 and pass == all) "Pass" else "Fail";
        std.debug.print("{s} {d}/{d}\n\n", .{ status, pass, all });
    }

    if (out == .json) {
        try std.json.stringify(output.items, .{ .whitespace = .indent_2 }, std.io.getStdOut().writer());
    }
}

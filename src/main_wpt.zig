const std = @import("std");

const jsruntime = @import("jsruntime");

const Suite = @import("wpt/testcase.zig").Suite;
const FileLoader = @import("wpt/fileloader.zig").FileLoader;
const wpt = @import("wpt/run.zig");

const DOM = @import("dom.zig");
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

// TODO For now the WPT tests run is specific to WPT.
// It manually load js framwork libs, and run the first script w/ js content in
// the HTML page.
// Once browsercore will have the html loader, it would be useful to refacto
// this test to use it.
pub fn main() !void {

    // generate APIs
    const apis = comptime jsruntime.compile(DOM.Interfaces);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // get the exec name.
    const execname = args.next().?;

    var json = false;
    var safe = false;
    var summary = false;

    var filter = std.ArrayList([]const u8).init(alloc);
    defer filter.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.io.getStdErr().writer().print(usage, .{execname});
            std.os.exit(0);
        }
        if (std.mem.eql(u8, "--json", arg)) {
            json = true;
            continue;
        }
        if (std.mem.eql(u8, "--safe", arg)) {
            safe = true;
            continue;
        }
        if (std.mem.eql(u8, "--summary", arg)) {
            summary = true;
            continue;
        }
        try filter.append(arg[0..]);
    }

    // both json and summary are incompatible.
    if (summary and json) {
        try std.io.getStdErr().writer().print("--json and --summary are incompatible\n", .{});
        std.os.exit(1);
    }
    // summary is available in safe mode only.
    if (summary) {
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
        for (list.items) |tc| {
            if (!shouldRun(filter.items, tc)) {
                continue;
            }

            // TODO use std.ChildProcess.run after next zig upgrade.
            var child = std.ChildProcess.init(&.{ execname, tc }, alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            var stdout = std.ArrayList(u8).init(alloc);
            var stderr = std.ArrayList(u8).init(alloc);
            defer {
                stdout.deinit();
                stderr.deinit();
            }

            try child.spawn();
            try child.collectOutput(&stdout, &stderr, 1024 * 1024);
            const term = try child.wait();

            const Result = enum {
                pass,
                fail,
                crash,
            };

            var result: Result = undefined;
            switch (term) {
                .Exited => |v| {
                    if (v == 0) {
                        result = .pass;
                    } else {
                        result = .fail;
                    }
                },
                .Signal => result = .crash,
                .Stopped => result = .crash,
                .Unknown => result = .crash,
            }

            if (summary) {
                switch (result) {
                    .pass => std.debug.print("Pass", .{}),
                    .fail => std.debug.print("Fail", .{}),
                    .crash => std.debug.print("Crash", .{}),
                }
                std.debug.print("\t{s}\n", .{tc});
                continue;
            }

            std.debug.print("{s}\n", .{stderr.items});
        }

        return;
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

        const res = wpt.run(&arena, apis, wpt_dir, tc, &loader) catch |err| {
            const suite = try Suite.init(alloc, tc, false, @errorName(err), null);
            try results.append(suite);

            if (!json) {
                std.debug.print("FAIL\t{s}\t{}\n", .{ tc, err });
            }
            failures += 1;
            continue;
        };
        // no need to call res.deinit() thanks to the arena allocator.

        const suite = try Suite.init(alloc, tc, res.success, res.result, res.stack);
        try results.append(suite);

        if (json) {
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

    if (json) {
        const Case = struct {
            pass: bool,
            name: []const u8,
            message: ?[]const u8,
        };
        const Test = struct {
            pass: bool,
            crash: bool = false, // TODO
            name: []const u8,
            cases: []Case,
        };

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
                    .message = suite.stack orelse suite.message,
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
        std.os.exit(0);
    }

    if (!json and failures > 0) {
        std.debug.print("{d}/{d} tests suites failures\n", .{ failures, run });
        std.os.exit(1);
    }
}

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

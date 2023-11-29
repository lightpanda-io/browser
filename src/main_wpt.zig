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

    std.debug.print("Running WPT test suite\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // get the exec name.
    const execname = args.next().?;

    var json = false;

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
        try filter.append(arg[0..]);
    }

    // initialize VM JS lib.
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // prepare libraries to load on each test case.
    var loader = FileLoader.init(alloc, wpt_dir);
    defer loader.deinit();

    // browse the dir to get the tests dynamically.
    var list = std.ArrayList([]const u8).init(alloc);
    try wpt.find(alloc, wpt_dir, &list);
    defer {
        for (list.items) |tc| {
            alloc.free(tc);
        }
        list.deinit();
    }

    var results = std.ArrayList(Suite).init(alloc);
    defer {
        for (results.items) |suite| {
            suite.deinit();
        }
        results.deinit();
    }

    var run: usize = 0;
    var failures: usize = 0;
    for (list.items) |tc| {
        if (filter.items.len > 0) {
            var match = false;
            for (filter.items) |f| {
                if (std.mem.startsWith(u8, tc, f)) {
                    match = true;
                    break;
                }
                if (std.mem.endsWith(u8, tc, f)) {
                    match = true;
                    break;
                }
            }
            if (!match) {
                continue;
            }
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

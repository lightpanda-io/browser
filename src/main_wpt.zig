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

const log = @import("log.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const App = @import("app.zig").App;
const Env = @import("browser/env.zig").Env;
const Browser = @import("browser/browser.zig").Browser;
const TestHTTPServer = @import("TestHTTPServer.zig");

const parser = @import("browser/netsurf.zig");
const polyfill = @import("browser/polyfill/polyfill.zig");

const WPT_DIR = "tests/wpt";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    log.opts.level = .err;

    var http_server = TestHTTPServer.init(httpHandler);
    defer http_server.deinit();

    {
        var wg: std.Thread.WaitGroup = .{};
        wg.startMany(1);
        var thrd = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &http_server, &wg });
        thrd.detach();
        wg.wait();
    }

    // An arena for the runner itself, lives for the duration of the the process
    var ra = ArenaAllocator.init(allocator);
    defer ra.deinit();
    const runner_arena = ra.allocator();

    const cmd = try parseArgs(runner_arena);

    var it = try TestIterator.init(allocator, WPT_DIR, cmd.filters);
    defer it.deinit();

    var writer = try Writer.init(allocator, cmd.format);
    defer writer.deinit();

    // An arena for running each tests. Is reset after every test.
    var test_arena = ArenaAllocator.init(allocator);
    defer test_arena.deinit();

    var app = try App.init(allocator, .{
        .run_mode = .fetch,
    });
    defer app.deinit();

    var browser = try Browser.init(app);
    defer browser.deinit();

    var i: usize = 0;
    while (try it.next()) |test_file| {
        defer _ = test_arena.reset(.retain_capacity);

        var err_out: ?[]const u8 = null;
        const result = run(
            test_arena.allocator(),
            &browser,
            test_file,
            &err_out,
        ) catch |err| blk: {
            if (err_out == null) {
                err_out = @errorName(err);
            }
            break :blk null;
        };
        try writer.process(test_file, result, err_out);
        // if (@mod(i, 10) == 0) {
        //     std.debug.print("\n\n=== V8 Memory {d}===\n", .{i});
        //     browser.env.dumpMemoryStats();
        // }
        i += 1;
    }
    try writer.finalize();
}

fn run(
    arena: Allocator,
    browser: *Browser,
    test_file: []const u8,
    err_out: *?[]const u8,
) ![]const u8 {
    const session = try browser.newSession();
    defer browser.closeSession();

    const page = try session.createPage();
    defer session.removePage();

    const url = try std.fmt.allocPrint(arena, "http://localhost:9582/{s}", .{test_file});
    try page.navigate(url, .{});

    _ = page.wait(2000);

    const js_context = page.main_context;
    var try_catch: Env.TryCatch = undefined;
    try_catch.init(js_context);
    defer try_catch.deinit();

    // Check the final test status.
    js_context.eval("report.status", "teststatus") catch |err| {
        err_out.* = try_catch.err(arena) catch @errorName(err) orelse "unknown";
        return err;
    };

    // return the detailed result.
    const value = js_context.exec("report.log", "report") catch |err| {
        err_out.* = try_catch.err(arena) catch @errorName(err) orelse "unknown";
        return err;
    };

    return value.toString(arena);
}

const Writer = struct {
    format: Format,
    allocator: Allocator,
    pass_count: usize = 0,
    fail_count: usize = 0,
    case_pass_count: usize = 0,
    case_fail_count: usize = 0,
    writer: std.fs.File.Writer,
    cases: std.ArrayListUnmanaged(Case) = .{},

    const Format = enum { json, text, summary, quiet };

    fn init(allocator: Allocator, format: Format) !Writer {
        const out = std.fs.File.stdout();
        var writer = out.writer(&.{});

        if (format == .json) {
            try writer.interface.writeByte('[');
        }

        return .{
            .format = format,
            .writer = writer,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Writer) void {
        self.cases.deinit(self.allocator);
    }

    fn finalize(self: *Writer) !void {
        var writer = &self.writer.interface;
        if (self.format == .json) {
            // When we write a test output, we add a trailing comma to act as
            // a separator for the next test. We need to add this dummy entry
            // to make it valid json.
            // Better option could be to change the formatter to work on JSONL:
            // https://github.com/lightpanda-io/perf-fmt/blob/main/wpt/wpt.go
            try writer.writeAll("{\"name\":\"empty\",\"pass\": true, \"cases\": []}]");
        } else {
            try writer.print("\n==Summary==\nTests: {d}/{d}\nCases: {d}/{d}\n", .{
                self.pass_count,
                self.pass_count + self.fail_count,
                self.case_pass_count,
                self.case_pass_count + self.case_fail_count,
            });
        }
    }

    fn process(self: *Writer, test_file: []const u8, result_: ?[]const u8, err_: ?[]const u8) !void {
        var writer = &self.writer.interface;
        if (err_) |err| {
            self.fail_count += 1;
            switch (self.format) {
                .text => return writer.print("Fail\t{s}\n\t{s}\n", .{ test_file, err }),
                .summary => return writer.print("Fail 0/0\t{s}\n", .{test_file}),
                .json => {
                    try std.json.Stringify.value(Test{
                        .pass = false,
                        .name = test_file,
                        .cases = &.{},
                    }, .{ .whitespace = .indent_2 }, writer);
                    return writer.writeByte(',');
                },
                .quiet => {},
            }
            // just make sure we didn't fall through by mistake
            unreachable;
        }

        // if we don't have an error, we must have a result
        const result = result_ orelse return error.InvalidResult;

        var cases = &self.cases;
        cases.clearRetainingCapacity(); // from previous run

        var pass = true;
        var case_pass_count: usize = 0;
        var case_fail_count: usize = 0;

        var lines = std.mem.splitScalar(u8, result, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                break;
            }
            // case names can have | in them, so we can't simply split on |
            var case_name = line;
            var case_pass = false; // so pessimistic!
            var case_message: []const u8 = "";

            if (std.mem.endsWith(u8, line, "|Pass")) {
                case_name = line[0 .. line.len - 5];
                case_pass = true;
                case_pass_count += 1;
            } else {
                // both cases names and messages can have | in them. Our only
                // chance to "parse" this is to anchor off the |$Status.
                const statuses = [_][]const u8{ "|Fail", "|Timeout", "|Not Run", "|Optional Feature Unsupported" };
                var pos_: ?usize = null;
                var message_start: usize = 0;
                for (statuses) |status| {
                    if (std.mem.indexOf(u8, line, status)) |idx| {
                        pos_ = idx;
                        message_start = idx + status.len;
                        break;
                    }
                }
                const pos = pos_ orelse {
                    std.debug.print("invalid result line: {s}\n", .{line});
                    return error.InvalidResult;
                };

                case_name = line[0..pos];
                case_message = line[message_start..];
                pass = false;
                case_fail_count += 1;
            }

            try cases.append(self.allocator, .{
                .name = case_name,
                .pass = case_pass,
                .message = case_message,
            });
        }

        // our global counters
        if (pass) {
            self.pass_count += 1;
        } else {
            self.fail_count += 1;
        }
        self.case_pass_count += case_pass_count;
        self.case_fail_count += case_fail_count;

        switch (self.format) {
            .summary => try writer.print("{s} {d}/{d}\t{s}\n", .{ statusText(pass), case_pass_count, case_pass_count + case_fail_count, test_file }),
            .text => {
                try writer.print("{s}\t{s}\n", .{ statusText(pass), test_file });
                for (cases.items) |c| {
                    try writer.print("\t{s}\t{s}\n", .{ statusText(c.pass), c.name });
                    if (c.message) |msg| {
                        try writer.print("\t\t{s}\n", .{msg});
                    }
                }
            },
            .json => {
                try std.json.Stringify.value(Test{
                    .pass = pass,
                    .name = test_file,
                    .cases = cases.items,
                }, .{ .whitespace = .indent_2 }, writer);
                // separator, see `finalize` for the hack we use to terminate this
                try writer.writeByte(',');
            },
            .quiet => {},
        }
    }

    fn statusText(pass: bool) []const u8 {
        return if (pass) "Pass" else "Fail";
    }
};

const Command = struct {
    format: Writer.Format,
    filters: [][]const u8,
};

fn parseArgs(arena: Allocator) !Command {
    const usage =
        \\usage: {s} [options] [test filter]
        \\  Run the Web Test Platform.
        \\
        \\  -h, --help       Print this help message and exit.
        \\  --json           result is formatted in JSON.
        \\  --summary        print a summary result. Incompatible w/ --json or --quiet
        \\  --quiet          No output. Incompatible w/ --json or --summary
        \\
    ;

    var args = try std.process.argsWithAllocator(arena);

    // get the exec name.
    const exec_name = args.next().?;

    var format = Writer.Format.text;
    var filters: std.ArrayListUnmanaged([]const u8) = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            std.debug.print(usage, .{exec_name});
            std.posix.exit(0);
        }

        if (std.mem.eql(u8, "--json", arg)) {
            format = .json;
        } else if (std.mem.eql(u8, "--summary", arg)) {
            format = .summary;
        } else if (std.mem.eql(u8, "--quiet", arg)) {
            format = .quiet;
        } else {
            try filters.append(arena, arg);
        }
    }

    return .{
        .format = format,
        .filters = filters.items,
    };
}

const TestIterator = struct {
    dir: Dir,
    walker: Dir.Walker,
    filters: [][]const u8,
    read_arena: ArenaAllocator,

    const Dir = std.fs.Dir;

    fn init(allocator: Allocator, root: []const u8, filters: [][]const u8) !TestIterator {
        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true, .no_follow = true });
        errdefer dir.close();

        return .{
            .dir = dir,
            .filters = filters,
            .walker = try dir.walk(allocator),
            .read_arena = ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *TestIterator) void {
        self.walker.deinit();
        self.dir.close();
        self.read_arena.deinit();
    }

    fn next(self: *TestIterator) !?[]const u8 {
        NEXT: while (try self.walker.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            if (std.mem.startsWith(u8, entry.path, "resources/")) {
                // resources for running the tests themselves, not actual tests
                continue;
            }

            if (!std.mem.endsWith(u8, entry.basename, ".html") and !std.mem.endsWith(u8, entry.basename, ".htm")) {
                continue;
            }

            const path = entry.path;
            for (self.filters) |filter| {
                if (std.mem.indexOf(u8, path, filter) == null) {
                    continue :NEXT;
                }
            }

            {
                defer _ = self.read_arena.reset(.retain_capacity);
                // We need to read the file's content to see if there's a
                // "testharness.js" in it. If there isn't, it isn't a test.
                // Shame we have to do this.

                const arena = self.read_arena.allocator();
                const full_path = try std.fs.path.join(arena, &.{ WPT_DIR, path });
                const file = try std.fs.cwd().openFile(full_path, .{});
                defer file.close();
                const html = try file.readToEndAlloc(arena, 128 * 1024);

                if (std.mem.indexOf(u8, html, "testharness.js") == null) {
                    // This isn't a test. A lot of files are helpers/content for tests to
                    // make use of.
                    continue :NEXT;
                }
            }

            return path;
        }

        return null;
    }
};

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

fn httpHandler(req: *std.http.Server.Request) !void {
    const path = req.head.target;

    if (std.mem.eql(u8, path, "/")) {
        // There's 1 test that does an XHR request to this, and it just seems
        // to want a 200 success.
        return req.respond("Hello!", .{});
    }

    var buf: [1024]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&buf, WPT_DIR ++ "{s}", .{path});
    return TestHTTPServer.sendFile(req, file_path);
}

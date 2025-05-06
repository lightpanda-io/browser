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
const ArenaAllocator = std.heap.ArenaAllocator;

const Env = @import("browser/env.zig").Env;
const Platform = @import("runtime/js.zig").Platform;

const parser = @import("browser/netsurf.zig");
const polyfill = @import("browser/polyfill/polyfill.zig");

const WPT_DIR = "tests/wpt";

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .info,
};

// TODO For now the WPT tests run is specific to WPT.
// It manually load js framwork libs, and run the first script w/ js content in
// the HTML page.
// Once lightpanda will have the html loader, it would be useful to refactor
// this test to use it.
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // An arena for the runner itself, lives for the duration of the the process
    var ra = ArenaAllocator.init(allocator);
    defer ra.deinit();
    const runner_arena = ra.allocator();

    const cmd = try parseArgs(runner_arena);

    const platform = try Platform.init();
    defer platform.deinit();

    // prepare libraries to load on each test case.
    var loader = FileLoader.init(runner_arena, WPT_DIR);

    var it = try TestIterator.init(runner_arena, WPT_DIR, cmd.filters);
    defer it.deinit();

    var writer = try Writer.init(runner_arena, cmd.format);

    // An arena for running each tests. Is reset after every test.
    var test_arena = ArenaAllocator.init(allocator);
    defer test_arena.deinit();

    while (try it.next()) |test_file| {
        defer _ = test_arena.reset(.{ .retain_capacity = {} });

        var err_out: ?[]const u8 = null;
        const result = run(test_arena.allocator(), test_file, &loader, &err_out) catch |err| blk: {
            if (err_out == null) {
                err_out = @errorName(err);
            }
            break :blk null;
        };

        if (result == null and err_out == null) {
            // We somtimes pass a non-test to `run` (we don't know it's a non
            // test, we need to open the contents of the test file to find out
            // and that's in run).
            continue;
        }

        try writer.process(test_file, result, err_out);
    }
    try writer.finalize();
}

fn run(arena: Allocator, test_file: []const u8, loader: *FileLoader, err_out: *?[]const u8) !?[]const u8 {
    // document
    const html = blk: {
        const full_path = try std.fs.path.join(arena, &.{ WPT_DIR, test_file });
        const file = try std.fs.cwd().openFile(full_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, 128 * 1024);
    };

    if (std.mem.indexOf(u8, html, "testharness.js") == null) {
        // This isn't a test. A lot of files are helpers/content for tests to
        // make use of.
        return null;
    }

    // this returns null for the success.html test in the root of tests/wpt
    const dirname = std.fs.path.dirname(test_file) orelse "";

    var runner = try @import("testing.zig").jsRunner(arena, .{
        .html = html,
    });
    defer runner.deinit();

    try polyfill.load(arena, runner.scope);

    // loop over the scripts.
    const doc = parser.documentHTMLToDocument(runner.state.document.?);
    const scripts = try parser.documentGetElementsByTagName(doc, "script");
    const script_count = try parser.nodeListLength(scripts);
    for (0..script_count) |i| {
        const s = (try parser.nodeListItem(scripts, @intCast(i))).?;

        // If the script contains an src attribute, load it.
        if (try parser.elementGetAttribute(@as(*parser.Element, @ptrCast(s)), "src")) |src| {
            var path = src;
            if (!std.mem.startsWith(u8, src, "/")) {
                path = try std.fs.path.join(arena, &.{ "/", dirname, path });
            }
            const script_source = loader.get(path) catch |err| {
                err_out.* = std.fmt.allocPrint(arena, "{s} - {s}", .{ @errorName(err), path }) catch null;
                return err;
            };
            try runner.exec(script_source, src, err_out);
        }

        // If the script as a source text, execute it.
        const src = try parser.nodeTextContent(s) orelse continue;
        try runner.exec(src, null, err_out);
    }

    {
        // Mark tests as ready to run.
        const loadevt = try parser.eventCreate();
        defer parser.eventDestroy(loadevt);

        try parser.eventInit(loadevt, "load", .{});
        _ = try parser.eventTargetDispatchEvent(
            parser.toEventTarget(@TypeOf(runner.window), &runner.window),
            loadevt,
        );
    }

    {
        // wait for all async executions
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(runner.scope);
        defer try_catch.deinit();
        try runner.loop.run();

        if (try_catch.hasCaught()) {
            err_out.* = (try try_catch.err(arena)) orelse "unknwon error";
        }
    }

    // Check the final test status.
    try runner.exec("report.status", "teststatus", err_out);

    // return the detailed result.
    const res = try runner.eval("report.log", "report", err_out);
    return try res.toString(arena);
}

const Writer = struct {
    format: Format,
    arena: Allocator,
    pass_count: usize = 0,
    fail_count: usize = 0,
    case_pass_count: usize = 0,
    case_fail_count: usize = 0,
    out: std.fs.File.Writer,
    cases: std.ArrayListUnmanaged(Case) = .{},

    const Format = enum {
        json,
        text,
        summary,
    };

    fn init(arena: Allocator, format: Format) !Writer {
        const out = std.io.getStdOut().writer();
        if (format == .json) {
            try out.writeByte('[');
        }

        return .{
            .out = out,
            .arena = arena,
            .format = format,
        };
    }

    fn finalize(self: *Writer) !void {
        if (self.format == .json) {
            // When we write a test output, we add a trailing comma to act as
            // a separator for the next test. We need to add this dummy entry
            // to make it valid json.
            // Better option could be to change the formatter to work on JSONL:
            // https://github.com/lightpanda-io/perf-fmt/blob/main/wpt/wpt.go
            try self.out.writeAll("{\"name\":\"empty\",\"pass\": true, \"cases\": []}]");
        } else {
            try self.out.print("\n==Summary==\nTests: {d}/{d}\nCases: {d}/{d}\n", .{
                self.pass_count,
                self.pass_count + self.fail_count,
                self.case_pass_count,
                self.case_pass_count + self.case_fail_count,
            });
        }
    }

    fn process(self: *Writer, test_file: []const u8, result_: ?[]const u8, err_: ?[]const u8) !void {
        if (err_) |err| {
            self.fail_count += 1;
            switch (self.format) {
                .text => return self.out.print("Fail\t{s}\n\t{s}\n", .{ test_file, err }),
                .summary => return self.out.print("Fail 0/0\t{s}\n", .{test_file}),
                .json => {
                    try std.json.stringify(Test{
                        .pass = false,
                        .name = test_file,
                        .cases = &.{},
                    }, .{ .whitespace = .indent_2 }, self.out);
                    return self.out.writeByte(',');
                },
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
            var fields = std.mem.splitScalar(u8, line, '|');
            const case_name = fields.next() orelse {
                std.debug.print("invalid result line: {s}\n", .{line});
                return error.InvalidResult;
            };

            const text_status = fields.next() orelse {
                std.debug.print("invalid result line: {s}\n", .{line});
                return error.InvalidResult;
            };

            const case_pass = std.mem.eql(u8, text_status, "Pass");
            if (case_pass) {
                case_pass_count += 1;
            } else {
                // If 1 case fails, we treat the entire file as a fail.
                pass = false;
                case_fail_count += 1;
            }

            try cases.append(self.arena, .{
                .name = case_name,
                .pass = case_pass,
                .message = fields.next(),
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
            .summary => try self.out.print("{s} {d}/{d}\t{s}\n", .{ statusText(pass), case_pass_count, case_pass_count + case_fail_count, test_file }),
            .text => {
                try self.out.print("{s}\t{s}\n", .{ statusText(pass), test_file });
                for (cases.items) |c| {
                    try self.out.print("\t{s}\t{s}\n", .{ statusText(c.pass), c.name });
                    if (c.message) |msg| {
                        try self.out.print("\t\t{s}\n", .{msg});
                    }
                }
            },
            .json => {
                try std.json.stringify(Test{
                    .pass = pass,
                    .name = test_file,
                    .cases = cases.items,
                }, .{ .whitespace = .indent_2 }, self.out);
                // separator, see `finalize` for the hack we use to terminate this
                try self.out.writeByte(',');
            },
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
        \\  --summary        print a summary result. Incompatible w/ --json
        \\
    ;

    var args = try std.process.argsWithAllocator(arena);

    // get the exec name.
    const execname = args.next().?;

    var format = Writer.Format.text;
    var filters: std.ArrayListUnmanaged([]const u8) = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.io.getStdErr().writer().print(usage, .{execname});
            std.posix.exit(0);
        }

        if (std.mem.eql(u8, "--json", arg)) {
            format = .json;
        } else if (std.mem.eql(u8, "--summary", arg)) {
            format = .summary;
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

    const Dir = std.fs.Dir;

    fn init(arena: Allocator, root: []const u8, filters: [][]const u8) !TestIterator {
        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true, .no_follow = true });
        errdefer dir.close();

        return .{
            .dir = dir,
            .filters = filters,
            .walker = try dir.walk(arena),
        };
    }

    fn deinit(self: *TestIterator) void {
        self.dir.close();
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

pub const FileLoader = struct {
    path: []const u8,
    arena: Allocator,
    files: std.StringHashMapUnmanaged([]const u8),

    pub fn init(arena: Allocator, path: []const u8) FileLoader {
        return .{
            .path = path,
            .files = .{},
            .arena = arena,
        };
    }
    pub fn get(self: *FileLoader, name: []const u8) ![]const u8 {
        const gop = try self.files.getOrPut(self.arena, name);
        if (gop.found_existing == false) {
            gop.key_ptr.* = try self.arena.dupe(u8, name);
            gop.value_ptr.* = self.load(name) catch |err| {
                _ = self.files.remove(name);
                return err;
            };
        }
        return gop.value_ptr.*;
    }

    fn load(self: *FileLoader, name: []const u8) ![]const u8 {
        const filename = try std.fs.path.join(self.arena, &.{ self.path, name });
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        return file.readToEndAlloc(self.arena, 4 * 1024 * 1024);
    }
};

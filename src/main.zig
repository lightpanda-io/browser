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
const Allocator = std.mem.Allocator;

const jsruntime = @import("jsruntime");

const Browser = @import("browser/browser.zig").Browser;
const server = @import("server.zig");

const parser = @import("netsurf");
const apiweb = @import("apiweb.zig");

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const UserContext = apiweb.UserContext;
pub const IO = @import("asyncio").Wrapper(jsruntime.Loop);
const version = @import("build_info").git_commit;

const log = std.log.scoped(.cli);

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .debug,

    // Define logFn to override the std implementation
    .logFn = logFn,
};

pub fn main() !void {
    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        _ = gpa.detectLeaks();
    };

    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try parseArgs(args_arena.allocator());

    switch (args.mode) {
        .help => args.printUsageAndExit(args.mode.help),
        .version => {
            std.debug.print("{s}\n", .{version});
            return std.process.cleanExit();
        },
        .serve => |opts| {
            const address = std.net.Address.parseIp4(opts.host, opts.port) catch |err| {
                log.err("address (host:port) {any}\n", .{err});
                return args.printUsageAndExit(false);
            };

            var app = try @import("app.zig").App.init(alloc, .serve);
            defer app.deinit();
            app.telemetry.record(.{ .run = {} });

            const timeout = std.time.ns_per_s * @as(u64, opts.timeout);
            server.run(&app, address, timeout) catch |err| {
                log.err("Server error", .{});
                return err;
            };
        },
        .fetch => |opts| {
            log.debug("Fetch mode: url {s}, dump {any}", .{ opts.url, opts.dump });

            var app = try @import("app.zig").App.init(alloc, .fetch);
            defer app.deinit();
            app.telemetry.record(.{ .run = {} });

            // vm
            const vm = jsruntime.VM.init();
            defer vm.deinit();

            // browser
            var browser = try Browser.init(&app);
            defer browser.deinit();

            var session = try browser.newSession({});

            // page
            const page = try session.createPage(null);

            _ = page.navigate(opts.url, null) catch |err| switch (err) {
                error.UnsupportedUriScheme, error.UriMissingHost => {
                    log.err("'{s}' is not a valid URL ({any})\n", .{ opts.url, err });
                    return args.printUsageAndExit(false);
                },
                else => {
                    log.err("'{s}' fetching error ({any})\n", .{ opts.url, err });
                    return err;
                },
            };

            try page.wait();

            // dump
            if (opts.dump) {
                try page.dump(std.io.getStdOut());
            }
        },
    }
}

const Command = struct {
    mode: Mode,
    exec_name: []const u8,

    const ModeType = enum {
        help,
        fetch,
        serve,
        version,
    };

    const Mode = union(ModeType) {
        help: bool, // false when being printed because of an error
        fetch: Fetch,
        serve: Serve,
        version: void,
    };

    const Serve = struct {
        host: []const u8,
        port: u16,
        timeout: u16,
    };

    const Fetch = struct {
        url: []const u8,
        dump: bool = false,
    };

    fn printUsageAndExit(self: *const Command, success: bool) void {
        const usage =
            \\usage: {s} command [options] [URL]
            \\
            \\Command can be either 'fetch', 'serve' or 'help'
            \\
            \\fetch command
            \\Fetches the specified URL
            \\Example: {s} fetch --dump https://lightpanda.io/
            \\
            \\Options:
            \\--dump          Dumps document to stdout.
            \\                Defaults to false.
            \\
            \\serve command
            \\Starts a websocket CDP server
            \\Example: {s} serve --host 127.0.0.1 --port 9222
            \\
            \\Options:
            \\--host          Host of the CDP server
            \\                Defaults to "127.0.0.1"
            \\
            \\--port          Port of the CDP server
            \\                Defaults to 9222
            \\
            \\--timeout       Inactivity timeout in seconds before disconnecting clients
            \\                Defaults to 3 (seconds)
            \\
            \\version command
            \\Displays the version of {s}
            \\
            \\help command
            \\Displays this message
        ;
        std.debug.print(usage, .{ self.exec_name, self.exec_name, self.exec_name, self.exec_name });
        if (success) {
            return std.process.cleanExit();
        }
        std.process.exit(1);
    }
};

fn parseArgs(allocator: Allocator) !Command {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const exec_name = std.fs.path.basename(args.next().?);

    var cmd = Command{
        .mode = .{ .help = false },
        .exec_name = try allocator.dupe(u8, exec_name),
    };

    const mode_string = args.next() orelse "";
    const mode = std.meta.stringToEnum(Command.ModeType, mode_string) orelse blk: {
        const inferred_mode = inferMode(mode_string) orelse return cmd;
        // "command" wasn't a command but an option. We can't reset args, but
        // we can create a new one. Not great, but this fallback is temporary
        // as we transition to this command mode approach.
        args.deinit();

        args = try std.process.argsWithAllocator(allocator);
        // skip the exec_name
        _ = args.skip();

        break :blk inferred_mode;
    };

    cmd.mode = switch (mode) {
        .help => .{ .help = true },
        .serve => .{ .serve = parseServeArgs(allocator, &args) catch return cmd },
        .fetch => .{ .fetch = parseFetchArgs(allocator, &args) catch return cmd },
        .version => .{ .version = {} },
    };
    return cmd;
}

fn inferMode(opt: []const u8) ?Command.ModeType {
    if (opt.len == 0) {
        return .serve;
    }

    if (std.mem.eql(u8, opt, "--dump")) {
        return .fetch;
    }
    if (std.mem.startsWith(u8, opt, "--") == false) {
        return .fetch;
    }

    if (std.mem.eql(u8, opt, "--host")) {
        return .serve;
    }

    if (std.mem.eql(u8, opt, "--port")) {
        return .serve;
    }

    if (std.mem.eql(u8, opt, "--timeout")) {
        return .serve;
    }
    return null;
}

fn parseServeArgs(
    allocator: Allocator,
    args: *std.process.ArgIterator,
) !Command.Serve {
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 9222;
    var timeout: u16 = 3;

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--host", opt)) {
            const str = args.next() orelse {
                log.err("--host argument requires an value", .{});
                return error.InvalidMissingHost;
            };
            host = try allocator.dupe(u8, str);
            continue;
        }

        if (std.mem.eql(u8, "--port", opt)) {
            const str = args.next() orelse {
                log.err("--port argument requires an value", .{});
                return error.InvalidMissingPort;
            };

            port = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.err("--port value is invalid: {}", .{err});
                return error.InvalidPort;
            };
            continue;
        }

        if (std.mem.eql(u8, "--timeout", opt)) {
            const str = args.next() orelse {
                log.err("--timeout argument requires an value", .{});
                return error.MissingTimeout;
            };

            timeout = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.err("--timeout value is invalid: {}", .{err});
                return error.InvalidTimeout;
            };
            continue;
        }

        log.err("Unknown option to serve command: '{s}'", .{opt});
        return error.UnkownOption;
    }

    return .{
        .host = host,
        .port = port,
        .timeout = timeout,
    };
}

fn parseFetchArgs(
    allocator: Allocator,
    args: *std.process.ArgIterator,
) !Command.Fetch {
    var dump: bool = false;
    var url: ?[]const u8 = null;

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--dump", opt)) {
            dump = true;
            continue;
        }

        if (std.mem.startsWith(u8, opt, "--")) {
            log.err("Unknown option to serve command: '{s}'", .{opt});
            return error.UnkownOption;
        }

        if (url != null) {
            log.err("Can only fetch 1 URL", .{});
            return error.TooManyURLs;
        }
        url = try allocator.dupe(u8, opt);
    }

    if (url == null) {
        log.err("A URL must be provided to the fetch command", .{});
        return error.MissingURL;
    }

    return .{ .url = url.?, .dump = dump };
}

var verbose: bool = builtin.mode == .Debug; // In debug mode, force verbose.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!verbose) {
        // hide all messages with level greater of equal to debug level.
        if (@intFromEnum(level) >= @intFromEnum(std.log.Level.debug)) return;
    }
    // default std log function.
    std.log.defaultLog(level, scope, format, args);
}

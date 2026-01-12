const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const abort = std.posix.abort;

// tracks how deep within a panic we're panicling
var panic_level: usize = 0;

// Locked to avoid interleaving panic messages from multiple threads.
var panic_mutex = std.Thread.Mutex{};

// overwrite's Zig default panic handler
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, begin_addr: ?usize) noreturn {
    @branchHint(.cold);
    crash(msg, .{ .source = "global" }, begin_addr orelse @returnAddress());
}

pub noinline fn crash(
    reason: []const u8,
    args: anytype,
    begin_addr: usize,
) noreturn {
    @branchHint(.cold);

    nosuspend switch (panic_level) {
        0 => {
            panic_level = panic_level + 1;

            {
                panic_mutex.lock();
                defer panic_mutex.unlock();

                var writer_w = std.fs.File.stderr().writerStreaming(&.{});
                const writer = &writer_w.interface;

                writer.writeAll(
                    \\
                    \\Lightpanda has crashed. Please report the issue:
                    \\https://github.com/lightpanda-io/browser/issues
                    \\
                ) catch abort();

                writer.print("\nreason: {s}\n", .{reason}) catch abort();
                writer.print("OS: {s}\n", .{@tagName(builtin.os.tag)}) catch abort();
                writer.print("mode: {s}\n", .{@tagName(builtin.mode)}) catch abort();
                writer.print("version: {s}\n", .{lp.build_config.git_commit}) catch abort();
                inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
                    writer.writeAll(f.name ++ ": ") catch break;
                    @import("log.zig").writeValue(.pretty, @field(args, f.name), writer) catch abort();
                    writer.writeByte('\n') catch abort();
                }

                std.debug.dumpCurrentStackTraceToWriter(begin_addr, writer) catch abort();
            }

            report(reason) catch {};
        },
        1 => {
            panic_level = 2;
            var stderr_w = std.fs.File.stderr().writerStreaming(&.{});
            const stderr = &stderr_w.interface;
            stderr.writeAll("panicked during a panic. Aborting.\n") catch abort();
        },
        else => {},
    };

    abort();
}

fn report(reason: []const u8) !void {
    if (@import("telemetry/telemetry.zig").isDisabled()) {
        return;
    }

    var curl_path: [2048]u8 = undefined;
    const curl_path_len = curlPath(&curl_path) orelse return;

    var args_buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&args_buffer);

    try writer.print("https://crash.lightpanda.io/?v={s}&r=", .{lp.build_config.git_commit});
    for (reason) |b| {
        switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_' => try writer.writeByte(b),
            ' ' => try writer.writeByte('+'),
            else => try writer.writeByte('!'), // some weird character, that we shouldn't have, but that'll we'll replace with a weird (bur url-safe) character
        }
    }

    try writer.writeByte(0);
    const url = writer.buffered();

    var argv = [_:null]?[*:0]const u8{
        curl_path[0..curl_path_len :0],
        "-fsSL",
        url[0 .. url.len - 1 :0],
    };
    std.debug.print("*{s}*\n", .{argv[2].?});

    const result = std.c.fork();
    switch (result) {
        0 => {
            _ = std.c.close(0);
            _ = std.c.close(1);
            _ = std.c.close(2);
            _ = std.c.execve(argv[0].?, &argv, std.c.environ);
            std.c.exit(0);
        },
        else => return,
    }
}

fn curlPath(buf: []u8) ?usize {
    const path = std.posix.getenv("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);

    var fba = std.heap.FixedBufferAllocator.init(buf);
    const allocator = fba.allocator();

    const cwd = std.fs.cwd();
    while (it.next()) |p| {
        defer fba.reset();
        const full_path = std.fs.path.joinZ(allocator, &.{ p, "curl" }) catch continue;
        cwd.accessZ(full_path, .{}) catch continue;
        return full_path.len;
    }
    return null;
}

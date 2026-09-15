// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const abort = std.process.abort;

// tracks how deep within a panic we're panicling
var panic_level: usize = 0;

// Locked to avoid interleaving panic messages from multiple threads.
var panic_mutex: std.Io.Mutex = .init;

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
                panic_mutex.lockUncancelable(lp.io);
                defer panic_mutex.unlock(lp.io);

                var writer_w = std.Io.File.stderr().writerStreaming(lp.io, &.{});
                const writer = &writer_w.interface;

                writer.writeAll(
                    \\
                    \\Lightpanda has crashed. Please report the issue:
                    \\https://github.com/lightpanda-io/browser/issues
                    \\or let us know on discord: https://discord.gg/g24PtgD6
                    \\
                ) catch abort();

                writer.print("\nreason: {s}\n", .{reason}) catch abort();
                writer.print("OS: {s}\n", .{@tagName(builtin.os.tag)}) catch abort();
                writer.print("mode: {s}\n", .{@tagName(builtin.mode)}) catch abort();
                writer.print("version: {s}\n", .{lp.build_config.version}) catch abort();
                inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
                    writer.writeAll(f.name ++ ": ") catch break;
                    lp.log.writeValue(.pretty, @field(args, f.name), writer) catch abort();
                    writer.writeByte('\n') catch abort();
                }

                std.debug.writeCurrentStackTrace(.{ .first_address = begin_addr }, .{ .writer = writer, .mode = .no_color }) catch abort();
            }

            report(reason, begin_addr, args) catch {};
        },
        1 => {
            panic_level = 2;
            var stderr_w = std.Io.File.stderr().writerStreaming(lp.io, &.{});
            const stderr = &stderr_w.interface;
            stderr.writeAll("panicked during a panic. Aborting.\n") catch abort();
        },
        else => {},
    };

    abort();
}

fn report(reason: []const u8, begin_addr: usize, args: anytype) !void {
    if (comptime lp.IS_DEBUG) {
        return;
    }

    if (@import("telemetry/telemetry.zig").isDisabled()) {
        return;
    }

    var curl_path: [2048]u8 = undefined;
    const curl_path_len = curlPath(&curl_path) orelse return;

    var url_buffer: [4096]u8 = undefined;
    const url = blk: {
        var writer: std.Io.Writer = .fixed(&url_buffer);
        try writer.print("https://crash.lightpanda.io/c?v={s}&r=", .{lp.build_config.version_encoded});
        for (reason) |b| {
            switch (b) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_' => try writer.writeByte(b),
                ' ' => try writer.writeByte('+'),
                else => try writer.writeByte('!'), // some weird character, that we shouldn't have, but that'll we'll replace with a weird (bur url-safe) character
            }
        }

        try writer.writeByte(0);
        break :blk writer.buffered();
    };

    var body_buffer: [8192]u8 = undefined;
    const body = blk: {
        var writer: std.Io.Writer = .fixed(body_buffer[0..8191]); // reserve 1 space
        inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
            // remove url value from the crash report.
            if (comptime std.mem.eql(u8, f.name, "url")) {
                writer.writeAll("url: REDACTED\n") catch break;
                continue;
            }
            writer.writeAll(f.name ++ ": ") catch break;
            lp.log.writeValue(.pretty, @field(args, f.name), &writer) catch {};
            writer.writeByte('\n') catch {};
        }

        std.debug.writeCurrentStackTrace(.{ .first_address = begin_addr }, .{ .writer = &writer, .mode = .no_color }) catch {};
        const written = writer.buffered();
        if (written.len == 0) {
            break :blk "???";
        }
        // Overwrite the last character with our null terminator
        // body_buffer always has to be > written
        body_buffer[written.len] = 0;
        break :blk body_buffer[0 .. written.len + 1];
    };

    var argv = [_:null]?[*:0]const u8{
        curl_path[0..curl_path_len :0],
        "-fsSL",
        "-H",
        "Content-Type: application/octet-stream",
        "--data-binary",
        body[0 .. body.len - 1 :0],
        url[0 .. url.len - 1 :0],
    };

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
    const path_z = std.c.getenv("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(path_z), std.fs.path.delimiter);

    var fba = std.heap.FixedBufferAllocator.init(buf);
    const allocator = fba.allocator();

    const cwd = std.Io.Dir.cwd();
    while (it.next()) |p| {
        defer fba.reset();
        const full_path = std.fs.path.joinZ(allocator, &.{ p, "curl" }) catch continue;
        cwd.access(lp.io, full_path, .{}) catch continue;
        return full_path.len;
    }
    return null;
}

const fatal_signals = [_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE };
// Initialized before threads start; owned until process exit.
var signal_pipe_fd: std.c.fd_t = -1;
var signal_handlers_attached = false;

// Best-effort record of a fatal signal, written before the process dies of
// it. Unlike panics, the interrupted thread may hold any lock, so this path
// never touches the panic mutex, lp.io, the unwinder, the allocator or
// telemetry: fixed-buffer scalar formatting, nonblocking output, re-raise.
//
// V8's WebAssembly trap handler is not enabled; enabling it would require
// giving it first chance at SIGSEGV/SIGBUS here.
pub fn attachSignalHandlers() void {
    if (builtin.os.tag != .linux or signal_handlers_attached) return;
    signal_handlers_attached = true;
    signal_pipe_fd = openSignalPipe();
    var mask = std.posix.sigemptyset();
    std.posix.sigaddset(&mask, .PIPE);
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handleFatalSignal },
        .mask = mask,
        .flags = std.posix.SA.SIGINFO | std.posix.SA.RESETHAND | std.posix.SA.NODEFER,
    };
    for (fatal_signals) |sig| std.posix.sigaction(sig, &act, null);
}

fn openSignalPipe() std.c.fd_t {
    if (builtin.os.tag != .linux) return -1;
    const raw_flags = std.c.fcntl(2, std.posix.F.GETFL);
    if (raw_flags < 0) return -1;
    const flags: std.posix.O = @bitCast(@as(u32, @intCast(raw_flags)));
    if (flags.ACCMODE == .RDONLY) return -1;
    var original: std.os.linux.Statx = undefined;
    if (!statPipe(2, &original)) return -1;
    // Unlike dup(), procfs gives us independent O_NONBLOCK flags.
    const fd = std.c.open("/proc/self/fd/2", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return -1;
    var reopened: std.os.linux.Statx = undefined;
    if (!statPipe(fd, &reopened) or reopened.dev_major != original.dev_major or
        reopened.dev_minor != original.dev_minor or reopened.ino != original.ino)
    {
        _ = std.c.close(fd);
        return -1;
    }
    return fd;
}

fn statPipe(fd: std.c.fd_t, stat: *std.os.linux.Statx) bool {
    const linux = std.os.linux;
    if (linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, stat) != 0) return false;
    return stat.mask.TYPE and stat.mask.INO and linux.S.ISFIFO(stat.mode);
}

fn handleFatalSignal(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) noreturn {
    // A secondary fault must not re-enter any reporting machinery.
    const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for (fatal_signals) |fatal| _ = std.c.sigaction(fatal, &default, null);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeSignalContext(&writer, sig, info, ctx_ptr) catch {};
    const record = writer.buffered();
    if (signal_pipe_fd >= 0) {
        _ = std.c.write(signal_pipe_fd, record.ptr, record.len);
    } else {
        // Per-call flags leave inherited stderr flags unchanged. Non-sockets
        // fail with ENOTSOCK: omit the record rather than risk blocking.
        _ = std.c.send(2, record.ptr, record.len, std.c.MSG.DONTWAIT | std.c.MSG.NOSIGNAL);
    }
    _ = std.c.raise(sig);
    std.c._exit(@intCast(128 + @intFromEnum(sig)));
}

fn writeSignalContext(writer: *std.Io.Writer, sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) !void {
    try writer.print("\nLightpanda fatal signal: {t} ({d})\nversion: {s}\nOS: {s}\nmode: {s}\ncode: {d}\n", .{
        sig, @intFromEnum(sig), lp.build_config.version, @tagName(builtin.os.tag), @tagName(builtin.mode), info.code,
    });
    if (faultAddress(info)) |address| {
        try writer.print("address: 0x{x}\n", .{address});
    } else {
        try writer.writeAll("address: unavailable\n");
    }
    // Runtime address of a known symbol for offline ASLR adjustment.
    try writer.print("crash_handler.handleFatalSignal: 0x{x}\n", .{@intFromPtr(&handleFatalSignal)});
    if (ctx_ptr != null) {
        if (std.debug.cpu_context.fromPosixSignalContext(ctx_ptr)) |ctx| {
            try writer.print("pc: 0x{x}\nfp: 0x{x}\n", .{ ctx.getPc(), ctx.getFp() });
            switch (builtin.cpu.arch) {
                .aarch64 => try writer.print("sp: 0x{x}\nlr: 0x{x}\n", .{ ctx.sp, ctx.x[30] }),
                .x86_64 => try writer.print("sp: 0x{x}\n", .{ctx.gprs.get(.rsp)}),
                else => {},
            }
        }
    }
}

fn faultAddress(info: *const std.posix.siginfo_t) ?usize {
    // SI_USER/SI_TKILL/SI_KERNEL do not supply si_addr.
    if (info.code <= 0 or info.code >= 128) return null;
    return @intFromPtr(info.fields.sigfault.addr);
}

const testing = @import("testing.zig");

test "crash_handler: fatal signals preserve termination with unavailable stderr" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for (fatal_signals) |sig| {
        for ([_]SignalTestMode{ .normal, .pipe, .closed, .broken_pipe, .locked_panic, .regular_file, .read_only_pipe }) |mode| {
            try testSignal(sig, mode);
        }
    }
}

test "crash_handler: full stderr must not delay termination" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for (fatal_signals) |sig| {
        try testSignal(sig, .full_pipe);
        try testSignal(sig, .full_socket);
    }
}

test "crash_handler: hardware fault reports the interrupted context" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testSignal(.SEGV, .hardware);
}

test "crash_handler: fatal signal after fork from a non-main thread" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Worker = struct {
        fn run(result: *?anyerror) void {
            testSignal(.SEGV, .hardware) catch |err| {
                result.* = err;
            };
        }
    };
    var result: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&result});
    thread.join();
    if (result) |err| return err;
}

test "crash_handler: unknown signal addresses are not read" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var info: std.posix.siginfo_t = undefined;
    for ([_]c_int{ 0, -1, -6, 128, 0x10001 }) |code| {
        info.code = code;
        try testing.expectEqual(@as(?usize, null), faultAddress(&info));
    }
}

const SignalTestMode = enum { normal, pipe, closed, broken_pipe, locked_panic, hardware, full_pipe, full_socket, regular_file, read_only_pipe };

fn testSignal(sig: std.posix.SIG, mode: SignalTestMode) !void {
    const guard = if (mode == .hardware) try std.posix.mmap(null, std.heap.pageSize(), .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) else null;
    defer if (guard) |memory| std.posix.munmap(memory);
    const file = if (mode == .regular_file) std.c.memfd_create("fatal-signal-test", std.c.MFD.CLOEXEC) else -1;
    if (mode == .regular_file) try testing.expectEqual(true, file >= 0);
    defer if (file >= 0) {
        _ = std.c.close(file);
    };
    var fds: [2]std.c.fd_t = undefined;
    const full = mode == .full_pipe or mode == .full_socket;
    const is_pipe = mode == .pipe or mode == .full_pipe or mode == .read_only_pipe;
    const result = if (is_pipe) std.c.pipe(&fds) else std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try testing.expectEqual(@as(c_int, 0), result);
    defer _ = std.c.close(fds[0]);
    const pid = std.c.fork();
    if (pid == -1) {
        _ = std.c.close(fds[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        // Keep a regression from hanging the runner or writing a large core.
        const limit: std.posix.rlimit = .{ .cur = 0, .max = 0 };
        _ = std.c.setrlimit(.CORE, &limit);
        const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.ALRM, &default, null);
        std.posix.sigaction(.PIPE, &default, null);
        _ = std.c.alarm(3);
        _ = std.c.dup2(if (mode == .read_only_pipe) fds[0] else fds[1], 2);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        if (mode == .closed) _ = std.c.close(2);
        if (file >= 0) {
            _ = std.c.dup2(file, 2);
            _ = std.c.close(file);
        }
        if (mode == .broken_pipe) {
            var broken: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&broken) != 0) std.c._exit(1);
            _ = std.c.close(broken[0]);
            _ = std.c.dup2(broken[1], 2);
            _ = std.c.close(broken[1]);
        }
        if (full) {
            const flags = std.c.fcntl(2, std.posix.F.GETFL);
            const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
            if (std.c.fcntl(2, std.posix.F.SETFL, flags | nonblock) < 0) std.c._exit(1);
            const fill = [_]u8{'x'} ** 1024;
            for ([_]usize{ fill.len, 1 }) |len| {
                while (true) {
                    const written = std.c.write(2, &fill, len);
                    if (written > 0) continue;
                    if (std.posix.errno(written) != .AGAIN) std.c._exit(1);
                    break;
                }
            }
            if (std.c.fcntl(2, std.posix.F.SETFL, flags) < 0) std.c._exit(1);
        }
        if (mode == .locked_panic) panic_mutex.lockUncancelable(lp.io);
        const flags_before = std.c.fcntl(2, std.posix.F.GETFL);
        attachSignalHandlers();
        const first_pipe = signal_pipe_fd;
        attachSignalHandlers();
        if (signal_pipe_fd != first_pipe) std.c._exit(1);
        if (std.c.fcntl(2, std.posix.F.GETFL) != flags_before) std.c._exit(1);
        if (signal_pipe_fd >= 0) {
            const pipe_flags: std.posix.O = @bitCast(@as(u32, @intCast(std.c.fcntl(signal_pipe_fd, std.posix.F.GETFL))));
            if (!pipe_flags.NONBLOCK) std.c._exit(1);
            if (std.c.fcntl(signal_pipe_fd, std.posix.F.GETFD) & std.posix.FD_CLOEXEC == 0) std.c._exit(1);
        }
        if (guard) |memory| @as(*volatile u8, @ptrCast(memory.ptr)).* = 1;
        _ = std.c.raise(sig);
        std.c._exit(1);
    }
    _ = std.c.close(fds[1]);
    var status: c_int = 0;
    if (full) try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    var output: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < output.len) {
        const count = std.c.read(fds[0], output[len..].ptr, output.len - len);
        if (count <= 0) break;
        len += @intCast(count);
    }
    if (!full) try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const raw: u32 = @bitCast(status);
    try testing.expectEqual(true, std.posix.W.IFSIGNALED(raw));
    errdefer std.debug.print("signal={t} mode={t} status=0x{x}\n", .{ sig, mode, raw });
    try testing.expectEqual(sig, std.posix.W.TERMSIG(raw));
    if (file >= 0) try testing.expectEqual(@as(std.c.off_t, 0), std.c.lseek(file, 0, std.c.SEEK.END));
    if (mode == .read_only_pipe or mode == .closed or mode == .broken_pipe or mode == .regular_file) try testing.expectEqual(@as(usize, 0), len);
    if (mode == .normal or mode == .locked_panic or mode == .hardware or mode == .pipe) {
        const text = output[0..len];
        errdefer std.debug.print("signal={t} mode={t}\n{s}\n", .{ sig, mode, text });
        try testing.expectEqual(true, std.mem.containsAtLeast(u8, text, 1, "Lightpanda fatal signal:"));
        try testing.expectEqual(true, std.mem.containsAtLeast(u8, text, 1, "\npc: 0x"));
        try testing.expectEqual(true, std.mem.containsAtLeast(u8, text, 1, "\ncrash_handler.handleFatalSignal: 0x"));
        if (mode == .hardware) {
            var address_buffer: [64]u8 = undefined;
            const address = try std.fmt.bufPrint(&address_buffer, "address: 0x{x}\n", .{@intFromPtr(guard.?.ptr)});
            try testing.expectEqual(true, std.mem.containsAtLeast(u8, text, 1, address));
        } else {
            try testing.expectEqual(true, std.mem.containsAtLeast(u8, text, 1, "address: unavailable\n"));
        }
    }
}

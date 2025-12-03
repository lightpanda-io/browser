//! This structure processes operating system signals (SIGINT, SIGTERM)
//! and runs callbacks to clean up the system gracefully.
//!
//! The structure does not clear the memory allocated in the arena,
//! clear the entire arena when exiting the program.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = @import("log.zig");

pub const SigHandler = struct {
    arena: Allocator,

    sigset: std.posix.sigset_t = undefined,
    handle_thread: ?std.Thread = null,

    attempt: u32 = 0,
    listeners: std.ArrayList(Listener) = .empty,

    pub const Listener = struct {
        args: []const u8,
        start: *const fn (context: *const anyopaque) void,
    };

    pub fn install(self: *SigHandler) !void {
        // Block SIGINT and SIGTERM for the current thread and all created from it
        self.sigset = std.posix.sigemptyset();
        std.posix.sigaddset(&self.sigset, std.posix.SIG.INT);
        std.posix.sigaddset(&self.sigset, std.posix.SIG.TERM);
        std.posix.sigaddset(&self.sigset, std.posix.SIG.QUIT);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &self.sigset, null);

        self.handle_thread = try std.Thread.spawn(.{ .allocator = self.arena }, SigHandler.sighandle, .{self});
        self.handle_thread.?.detach();
    }

    pub fn on(self: *SigHandler, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
        assert(@typeInfo(@TypeOf(func)).@"fn".return_type.? == void);

        const Args = @TypeOf(args);
        const TypeErased = struct {
            fn start(context: *const anyopaque) void {
                const args_casted: *const Args = @ptrCast(@alignCast(context));
                @call(.auto, func, args_casted.*);
            }
        };

        const buffer = try self.arena.alignedAlloc(u8, .of(Args), @sizeOf(Args));
        errdefer self.arena.free(buffer);

        const bytes: []const u8 = @ptrCast((&args)[0..1]);
        @memcpy(buffer, bytes);

        try self.listeners.append(self.arena, .{
            .args = buffer,
            .start = TypeErased.start,
        });
    }

    fn sighandle(self: *SigHandler) noreturn {
        while (true) {
            var sig: c_int = 0;

            const rc = std.c.sigwait(&self.sigset, &sig);
            if (rc != 0) {
                log.err(.app, "Unable to process signal {}", .{rc});
                std.process.exit(1);
            }

            switch (sig) {
                std.posix.SIG.INT, std.posix.SIG.TERM => {
                    if (self.attempt > 1) {
                        std.process.exit(1);
                    }
                    self.attempt += 1;

                    log.info(.app, "Received termination signal...", .{});
                    for (self.listeners.items) |*item| {
                        item.start(item.args.ptr);
                    }
                    continue;
                },
                else => continue,
            }
        }
    }
};

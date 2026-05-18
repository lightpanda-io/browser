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

// Thread-safe inbox for CDP messages.
//
// A dedicated reader thread owns the CDP websocket's read side, parses
// frames, and `push`es each message onto this queue. The worker thread
// drains the queue at safe points (Runner.tick, HttpClient.syncRequest,
// ScriptManagerBase.waitForImport). The wake pipe (wake_read/wake_write)
// is what HttpClient.perform polls in place of the bare socket fd, so
// the runner still unblocks immediately when a message arrives.
//
// Concurrency contract:
//   - exactly one producer (the reader thread) calls push() / close().
//   - exactly one consumer (the worker thread) calls pop() / drainWake() /
//     freeMessage() / deinit().
//   - bytes on the wake pipe are signals only; values are ignored.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const Mailbox = @This();

allocator: Allocator,
mutex: Mutex = .{},

// FIFO of received CDP messages. Each item's `bytes` is owned by the
// mailbox until the consumer calls freeMessage().
queue: std.ArrayList(Message) = .empty,

// Set by the reader thread on EOF, fatal error, or shutdown request. Once
// `closed` is true and `queue` is empty, the connection is over.
closed: bool = false,

// Fatal error from the reader thread, if any (logged by the consumer).
err: ?anyerror = null,

// Self-pipe used to wake the consumer's poll loop. The read end gets
// registered with HttpClient.perform via CDPClient.socket; the producer
// writes a single byte on every push() and close().
wake_read: posix.fd_t,
wake_write: posix.fd_t,

pub const Message = struct {
    bytes: []u8,
};

pub fn init(allocator: Allocator) !Mailbox {
    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    return .{
        .allocator = allocator,
        .wake_read = pipe[0],
        .wake_write = pipe[1],
    };
}

pub fn deinit(self: *Mailbox) void {
    // Caller has joined the reader thread by now, so no concurrent push.
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.queue.items) |msg| self.allocator.free(msg.bytes);
    self.queue.deinit(self.allocator);
    posix.close(self.wake_read);
    posix.close(self.wake_write);
}

// Producer: enqueue a copy of `bytes` and wake the consumer. Drops the
// message if the mailbox has already been closed (consumer is tearing
// down). Returns the OOM error only on copy failure.
pub fn push(self: *Mailbox, bytes: []const u8) !void {
    const copy = try self.allocator.dupe(u8, bytes);
    errdefer self.allocator.free(copy);

    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) {
            self.allocator.free(copy);
            return;
        }
        try self.queue.append(self.allocator, .{ .bytes = copy });
    }

    self.wake();
}

// Producer: mark the mailbox closed and (optionally) record a fatal error.
// Wakes the consumer so it can observe the close. Idempotent — calling
// twice is fine.
pub fn close(self: *Mailbox, err: ?anyerror) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return;
        self.closed = true;
        if (err) |e| self.err = e;
    }
    self.wake();
}

pub const Pop = union(enum) {
    msg: []u8,
    closed: ?anyerror, // empty queue + closed flag
    empty: void, // empty queue, producer still live
};

// Consumer: pop the next message. If a `.msg` is returned, the caller
// owns the bytes and must release them via `freeMessage`.
pub fn pop(self: *Mailbox) Pop {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.queue.items.len > 0) {
        const m = self.queue.orderedRemove(0);
        return .{ .msg = m.bytes };
    }
    if (self.closed) return .{ .closed = self.err };
    return .empty;
}

pub fn freeMessage(self: *Mailbox, bytes: []u8) void {
    self.allocator.free(bytes);
}

// Consumer: drain any pending wake bytes from the pipe. Cheap — bytes on
// the wake pipe are signals, not data. Called by the consumer after it
// observes readiness on `wake_read` (perform's curl_multi_poll).
pub fn drainWake(self: *Mailbox) void {
    var buf: [256]u8 = undefined;
    while (true) {
        _ = posix.read(self.wake_read, &buf) catch return;
    }
}

fn wake(self: *Mailbox) void {
    const b: [1]u8 = .{1};
    // Best effort. The pipe is non-blocking; if it's full the consumer
    // already has a pending wake byte and will see the queued message
    // on its next pass.
    _ = posix.write(self.wake_write, &b) catch {};
}

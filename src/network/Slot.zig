// A Slot couples a wakeup pipe with a thread-safe linked-list queue. One
// consumer polls the pipe fd and drains the queue; any thread may push
// nodes or wake the consumer. Used to deliver completed transfers (and
// other cross-thread signals) from the main/Network thread to a worker.

const std = @import("std");
const posix = std.posix;

const Slot = @This();

_pipe: [2]posix.fd_t,
_mutex: std.Thread.Mutex = .{},
_queue: std.DoublyLinkedList = .{},

pub fn init() !Slot {
    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    return .{ ._pipe = pipe };
}

pub fn deinit(self: *Slot) void {
    for (&self._pipe) |*fd| {
        if (fd.* >= 0) {
            posix.close(fd.*);
            fd.* = -1;
        }
    }
}

pub fn pollFd(self: *const Slot) posix.fd_t {
    return self._pipe[0];
}

pub fn wake(self: *Slot) void {
    _ = posix.write(self._pipe[1], &.{1}) catch {};
}

pub fn push(self: *Slot, node: *std.DoublyLinkedList.Node) void {
    self._mutex.lock();
    self._queue.append(node);
    self._mutex.unlock();
    self.wake();
}

// Consumer drains signal bytes first, then pops all queued nodes.
// Pipe-first ordering ensures pushes that race with drain are not lost:
// producer writes the queue before the byte, so any byte observed implies
// the queued node is visible on the next lock.
pub fn drain(self: *Slot) std.DoublyLinkedList {
    var buf: [64]u8 = undefined;
    while (true) {
        _ = posix.read(self._pipe[0], &buf) catch break;
    }

    self._mutex.lock();
    defer self._mutex.unlock();

    var out: std.DoublyLinkedList = .{};
    while (self._queue.popFirst()) |n| out.append(n);
    return out;
}

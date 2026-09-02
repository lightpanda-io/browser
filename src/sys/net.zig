// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierres Tachoire <pierre@lightpanda.io>
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

// Errno-checked wrappers over libc socket primitives. Zig 0.16 removed these
// from std.posix. This is quicker than moving over to std.Io (especially since
// networking is half-baked).

const std = @import("std");
const builtin = @import("builtin");

const c = std.c;
const posix = std.posix;
const native_os = builtin.os.tag;

pub const socket_t = posix.socket_t;
pub const IpAddress = std.Io.net.IpAddress;

pub fn family(a: *const IpAddress) u32 {
    return switch (a.*) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
}

pub const Sockaddr = struct {
    storage: posix.sockaddr.storage,
    len: posix.socklen_t,

    pub fn ptr(self: *const Sockaddr) *const posix.sockaddr {
        return @ptrCast(&self.storage);
    }
};

pub fn sockaddrFromAddress(a: *const IpAddress) Sockaddr {
    var out: Sockaddr = .{ .storage = undefined, .len = 0 };
    switch (a.*) {
        .ip4 => |ip4| {
            const sa: *posix.sockaddr.in = @ptrCast(@alignCast(&out.storage));
            sa.* = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            out.len = @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            const sa: *posix.sockaddr.in6 = @ptrCast(@alignCast(&out.storage));
            sa.* = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .addr = ip6.bytes,
                .flowinfo = ip6.flow,
                .scope_id = ip6.interface.index,
            };
            out.len = @sizeOf(posix.sockaddr.in6);
        },
    }
    return out;
}

pub fn addressFromSockaddr(addr: *align(4) const posix.sockaddr) IpAddress {
    switch (addr.family) {
        posix.AF.INET => {
            const sa: *const posix.sockaddr.in = @ptrCast(addr);
            return .{ .ip4 = .{
                .bytes = @bitCast(sa.addr),
                .port = std.mem.bigToNative(u16, sa.port),
            } };
        },
        posix.AF.INET6 => {
            const sa: *const posix.sockaddr.in6 = @ptrCast(addr);
            return .{ .ip6 = .{
                .bytes = sa.addr,
                .port = std.mem.bigToNative(u16, sa.port),
                .flow = sa.flowinfo,
                .interface = .{ .index = sa.scope_id },
            } };
        },
        else => unreachable,
    }
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) !socket_t {
    // Darwin's socket() rejects flag bits in the type argument (its
    // SOCK.NONBLOCK/CLOEXEC are Zig-invented shim values); strip them and
    // apply via fcntl instead. Linux/FreeBSD accept them natively.
    const flag_bits = posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const extra: u32 = if (comptime builtin.os.tag.isDarwin()) socket_type & flag_bits else 0;
    const rc = c.socket(domain, socket_type & ~extra, protocol);
    if (rc < 0) {
        return errnoError(c.errno(rc));
    }
    errdefer _ = c.close(rc);
    if (extra & posix.SOCK.NONBLOCK != 0) {
        const fl = try fcntl(rc, posix.F.GETFL, 0);
        _ = try fcntl(rc, posix.F.SETFL, fl | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    }
    if (extra & posix.SOCK.CLOEXEC != 0) {
        _ = try fcntl(rc, posix.F.SETFD, posix.FD_CLOEXEC);
    }
    return rc;
}

pub fn bind(sock: socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    const rc = c.bind(sock, addr, len);
    if (rc != 0) {
        return errnoError(c.errno(rc));
    }
}

pub fn listen(sock: socket_t, backlog: u31) !void {
    const rc = c.listen(sock, backlog);
    if (rc != 0) {
        return errnoError(c.errno(rc));
    }
}

pub fn accept(sock: socket_t, addr: ?*posix.sockaddr, addr_size: ?*posix.socklen_t, flags: u32) !socket_t {
    const have_accept4 = !(builtin.target.os.tag.isDarwin() or native_os == .windows or native_os == .haiku);

    const accepted_sock: socket_t = while (true) {
        const rc = if (have_accept4)
            c.accept4(sock, addr, addr_size, flags)
        else
            c.accept(sock, addr, addr_size);

        if (rc < 0) {
            switch (c.errno(rc)) {
                .INTR => continue,
                else => |e| return errnoError(e),
            }
        }
        break rc;
    };

    if (have_accept4 == false) {
        errdefer _ = c.close(accepted_sock);
        if (flags & posix.SOCK.NONBLOCK != 0) {
            const fl = try fcntl(accepted_sock, posix.F.GETFL, 0);
            _ = try fcntl(accepted_sock, posix.F.SETFL, fl | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        }
        if (flags & posix.SOCK.CLOEXEC != 0) {
            _ = try fcntl(accepted_sock, posix.F.SETFD, posix.FD_CLOEXEC);
        }
    }
    return accepted_sock;
}

pub const ShutdownHow = enum { recv, send, both };

pub fn shutdown(sock: socket_t, how: ShutdownHow) !void {
    const c_how: c_int = switch (how) {
        .recv => c.SHUT.RD,
        .send => c.SHUT.WR,
        .both => c.SHUT.RDWR,
    };
    const rc = c.shutdown(sock, c_how);
    if (rc != 0) {
        return errnoError(c.errno(rc));
    }
}

pub fn getsockname(sock: socket_t, addr: *posix.sockaddr, len: *posix.socklen_t) !void {
    const rc = c.getsockname(sock, addr, len);
    if (rc != 0) {
        return errnoError(c.errno(rc));
    }
}

pub fn connect(addr: *const IpAddress) !socket_t {
    const sock = try socket(family(addr), posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer _ = c.close(sock);
    const sa = sockaddrFromAddress(addr);
    const rc = c.connect(sock, sa.ptr(), sa.len);
    if (rc != 0) {
        return errnoError(c.errno(rc));
    }
    return sock;
}

pub fn writeAll(sock: socket_t, bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        pos += try write(sock, bytes[pos..]);
    }
}

pub fn write(sock: socket_t, bytes: []const u8) !usize {
    const rc = c.write(sock, bytes.ptr, bytes.len);
    if (rc < 0) {
        return switch (c.errno(rc)) {
            .AGAIN => error.WouldBlock,
            .INTR => error.Interrupted,
            .PIPE => error.BrokenPipe,
            .CONNRESET => error.ConnectionResetByPeer,
            else => |e| posix.unexpectedErrno(e),
        };
    }
    return @intCast(rc);
}

pub fn fcntl(fd: posix.fd_t, cmd: i32, arg: usize) !usize {
    const rc = c.fcntl(fd, @as(c_int, cmd), arg);
    if (rc < 0) {
        return errnoError(c.errno(rc));
    }
    return @intCast(rc);
}

pub fn close(fd: posix.fd_t) void {
    switch (c.errno(c.close(fd))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => {}, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => {},
    }
}

pub fn epoll_create1(flags: u32) !i32 {
    const rc = c.epoll_create1(flags);
    return switch (c.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => unreachable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn eventfd(initval: u32, flags: u32) !i32 {
    const rc = c.eventfd(initval, flags);
    return switch (c.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => unreachable, // invalid parameters
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.SystemResources,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn epoll_ctl(epfd: i32, op: u32, fd: i32, event: ?*c.epoll_event) !void {
    const rc = c.epoll_ctl(epfd, op, fd, event);
    return switch (c.errno(rc)) {
        .SUCCESS => {},
        .BADF => unreachable, // always a race condition if this happens
        .EXIST => error.FileDescriptorAlreadyPresentInSet,
        .INVAL => unreachable,
        .LOOP => error.OperationCausesCircularLoop,
        .NOENT => error.FileDescriptorNotRegistered,
        .NOMEM => error.SystemResources,
        .NOSPC => error.UserResourceLimitReached,
        .PERM => error.FileDescriptorIncompatibleWithEpoll,
        else => error.Unexpected,
    };
}

pub fn epoll_wait(epfd: i32, events: []c.epoll_event, timeout: i32) usize {
    while (true) {
        // TODO get rid of the @intCast
        const rc = c.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => unreachable,
            .FAULT => unreachable,
            .INVAL => unreachable,
            else => unreachable,
        }
    }
}

pub fn kqueue() !i32 {
    const rc = c.kqueue();
    return switch (c.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
}

pub fn kevent(kq: i32, changes: []const c.Kevent, events: []c.Kevent, timeout: ?*const c.timespec) !usize {
    while (true) {
        const rc = c.kevent(kq, changes.ptr, @intCast(changes.len), events.ptr, @intCast(events.len), timeout);
        switch (c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => unreachable, // always a race condition if this happens
            .FAULT => unreachable,
            .INVAL => unreachable,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            else => return error.Unexpected,
        }
    }
}

fn errnoError(e: posix.E) anyerror {
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .ACCES => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .INVAL => error.InvalidArgument,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTSOCK => error.NotASocket,
        .NOTCONN => error.SocketNotConnected,
        .CONNABORTED => error.ConnectionAborted,
        .INTR => error.Interrupted,
        else => posix.unexpectedErrno(e),
    };
}

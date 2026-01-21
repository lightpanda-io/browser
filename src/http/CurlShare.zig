// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const Http = @import("Http.zig");
const c = Http.c;

/// Thread-safe wrapper for libcurl's share handle.
/// Allows multiple CURLM handles (one per session thread) to share:
/// - DNS resolution cache
/// - TLS session resumption data
/// - Connection pool
const CurlShare = @This();

handle: *c.CURLSH,
dns_mutex: std.Thread.Mutex,
ssl_mutex: std.Thread.Mutex,
conn_mutex: std.Thread.Mutex,
allocator: Allocator,

pub fn init(allocator: Allocator) !*CurlShare {
    const share = try allocator.create(CurlShare);
    errdefer allocator.destroy(share);

    const handle = c.curl_share_init() orelse return error.FailedToInitializeShare;
    errdefer _ = c.curl_share_cleanup(handle);

    share.* = .{
        .handle = handle,
        .dns_mutex = .{},
        .ssl_mutex = .{},
        .conn_mutex = .{},
        .allocator = allocator,
    };

    // Set up lock/unlock callbacks
    try errorSHCheck(c.curl_share_setopt(handle, c.CURLSHOPT_LOCKFUNC, @as(?*const fn (?*c.CURL, c.curl_lock_data, c.curl_lock_access, ?*anyopaque) callconv(.c) void, &lockFunc)));
    try errorSHCheck(c.curl_share_setopt(handle, c.CURLSHOPT_UNLOCKFUNC, @as(?*const fn (?*c.CURL, c.curl_lock_data, ?*anyopaque) callconv(.c) void, &unlockFunc)));
    try errorSHCheck(c.curl_share_setopt(handle, c.CURLSHOPT_USERDATA, @as(?*anyopaque, share)));

    // Configure what data to share
    try errorSHCheck(c.curl_share_setopt(handle, c.CURLSHOPT_SHARE, c.CURL_LOCK_DATA_DNS));
    try errorSHCheck(c.curl_share_setopt(handle, c.CURLSHOPT_SHARE, c.CURL_LOCK_DATA_SSL_SESSION));
    try errorSHCheck(c.curl_share_setopt(handle, c.CURLSHOPT_SHARE, c.CURL_LOCK_DATA_CONNECT));

    return share;
}

pub fn deinit(self: *CurlShare) void {
    _ = c.curl_share_cleanup(self.handle);
    self.allocator.destroy(self);
}

pub fn getHandle(self: *CurlShare) *c.CURLSH {
    return self.handle;
}

fn lockFunc(_: ?*c.CURL, data: c.curl_lock_data, _: c.curl_lock_access, userptr: ?*anyopaque) callconv(.c) void {
    const self: *CurlShare = @ptrCast(@alignCast(userptr));
    const mutex = self.getMutex(data) orelse return;
    mutex.lock();
}

fn unlockFunc(_: ?*c.CURL, data: c.curl_lock_data, userptr: ?*anyopaque) callconv(.c) void {
    const self: *CurlShare = @ptrCast(@alignCast(userptr));
    const mutex = self.getMutex(data) orelse return;
    mutex.unlock();
}

fn getMutex(self: *CurlShare, data: c.curl_lock_data) ?*std.Thread.Mutex {
    return switch (data) {
        c.CURL_LOCK_DATA_DNS => &self.dns_mutex,
        c.CURL_LOCK_DATA_SSL_SESSION => &self.ssl_mutex,
        c.CURL_LOCK_DATA_CONNECT => &self.conn_mutex,
        else => null,
    };
}

fn errorSHCheck(code: c.CURLSHcode) !void {
    if (code == c.CURLSHE_OK) {
        return;
    }
    return switch (code) {
        c.CURLSHE_BAD_OPTION => error.ShareBadOption,
        c.CURLSHE_IN_USE => error.ShareInUse,
        c.CURLSHE_INVALID => error.ShareInvalid,
        c.CURLSHE_NOMEM => error.OutOfMemory,
        c.CURLSHE_NOT_BUILT_IN => error.ShareNotBuiltIn,
        else => error.ShareUnknown,
    };
}

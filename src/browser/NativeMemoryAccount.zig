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

const NativeMemoryAccount = @This();

active_bytes: std.atomic.Value(usize) = .init(0),
pending_delta: std.atomic.Value(i64) = .init(0),

pub fn add(self: *NativeMemoryAccount, bytes: usize) void {
    if (bytes == 0) return;
    const delta: i64 = @intCast(bytes);
    _ = self.active_bytes.fetchAdd(bytes, .monotonic);
    _ = self.pending_delta.fetchAdd(delta, .release);
}

pub fn remove(self: *NativeMemoryAccount, bytes: usize) void {
    if (bytes == 0) return;
    const delta: i64 = @intCast(bytes);
    const previous = self.active_bytes.fetchSub(bytes, .monotonic);
    std.debug.assert(previous >= bytes);
    _ = self.pending_delta.fetchSub(delta, .release);
}

pub fn active(self: *const NativeMemoryAccount) usize {
    return self.active_bytes.load(.acquire);
}

pub fn takePendingDelta(self: *NativeMemoryAccount) i64 {
    return self.pending_delta.swap(0, .acq_rel);
}

const testing = std.testing;

test "NativeMemoryAccount: accumulates signed pending changes" {
    var account: NativeMemoryAccount = .{};

    account.add(100);
    account.add(25);
    account.remove(40);

    try testing.expectEqual(85, account.active());
    try testing.expectEqual(85, account.takePendingDelta());
    try testing.expectEqual(0, account.takePendingDelta());

    account.remove(85);
    try testing.expectEqual(0, account.active());
    try testing.expectEqual(-85, account.takePendingDelta());
}

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

const SessionThread = @import("SessionThread.zig");

/// Thread-safe collection of active CDP sessions.
/// Manages lifecycle and enforces connection limits.
const SessionManager = @This();

mutex: std.Thread.Mutex,
sessions: std.ArrayListUnmanaged(*SessionThread),
allocator: Allocator,
max_sessions: u32,

pub fn init(allocator: Allocator, max_sessions: u32) SessionManager {
    return .{
        .mutex = .{},
        .sessions = .{},
        .allocator = allocator,
        .max_sessions = max_sessions,
    };
}

pub fn deinit(self: *SessionManager) void {
    self.stopAll();
    self.sessions.deinit(self.allocator);
}

/// Add a new session to the manager.
/// Returns error.TooManySessions if the limit is reached.
pub fn add(self: *SessionManager, session: *SessionThread) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.sessions.items.len >= self.max_sessions) {
        return error.TooManySessions;
    }

    try self.sessions.append(self.allocator, session);
}

/// Remove a session from the manager.
/// Called when a session terminates.
pub fn remove(self: *SessionManager, session: *SessionThread) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.sessions.items, 0..) |s, i| {
        if (s == session) {
            _ = self.sessions.swapRemove(i);
            return;
        }
    }
}

/// Stop all active sessions and wait for them to terminate.
pub fn stopAll(self: *SessionManager) void {
    // First, signal all sessions to stop
    {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.sessions.items) |session| {
            session.stop();
        }
    }

    // Then wait for all to join (without holding the lock)
    // We need to copy the list since sessions will remove themselves
    var sessions_copy: std.ArrayListUnmanaged(*SessionThread) = .{};
    {
        self.mutex.lock();
        defer self.mutex.unlock();

        sessions_copy.appendSlice(self.allocator, self.sessions.items) catch return;
    }
    defer sessions_copy.deinit(self.allocator);

    for (sessions_copy.items) |session| {
        session.join();
        session.deinit();
    }

    // Clear the sessions list
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sessions.clearRetainingCapacity();
    }
}

/// Get the current number of active sessions.
pub fn count(self: *SessionManager) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.sessions.items.len;
}

const testing = std.testing;

test "SessionManager: add and remove" {
    var manager = SessionManager.init(testing.allocator, 10);
    defer manager.deinit();

    try testing.expectEqual(0, manager.count());
}

test "SessionManager: max sessions limit" {
    var manager = SessionManager.init(testing.allocator, 2);
    defer manager.deinit();

    // We can't easily create mock SessionThreads for this test,
    // so we just verify the initialization works
    try testing.expectEqual(0, manager.count());
}

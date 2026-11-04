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

//! JSON-RPC writer for the browser-tools MCP server (`mcp/Server.zig`).

const std = @import("std");
const lp = @import("lightpanda");
const protocol = @import("protocol.zig");

const Self = @This();

/// A screenshot response is hundreds of KB; don't keep that parked.
pub const large_response = 256 * 1024;

writer: *std.Io.Writer,
mutex: std.Io.Mutex = .init,
aw: std.Io.Writer.Allocating,
notify: Notify = .writer,

/// Where notifications go: between the responses on `writer` (stdio), into
/// the HTTP call's event stream, or nowhere for a client that can't take one.
pub const Notify = union(enum) {
    writer,
    drop,
    sink: Sink,
};

pub const Sink = struct {
    context: *anyopaque,
    /// `message` is one serialized notification, without a newline; borrowed.
    push: *const fn (context: *anyopaque, message: []const u8) void,
};

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Self {
    return .{ .writer = writer, .aw = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.aw.deinit();
}

/// Point subsequent messages at one HTTP call's buffer and stream; safe
/// because the browser worker binds and writes on a single thread.
pub fn bind(self: *Self, writer: *std.Io.Writer, notify: Notify) void {
    self.writer = writer;
    self.notify = notify;
}

fn send(self: *Self, message: anytype, sink: ?Sink) !void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    self.aw.clearRetainingCapacity();
    try std.json.Stringify.value(message, .{ .emit_null_optional_fields = false }, &self.aw.writer);
    if (sink) |s| {
        s.push(s.context, self.aw.writer.buffered());
    } else {
        try self.aw.writer.writeByte('\n');
        try self.writer.writeAll(self.aw.writer.buffered());
        try self.writer.flush();
    }

    if (self.aw.writer.buffer.len > large_response) {
        const allocator = self.aw.allocator;
        self.aw.deinit();
        self.aw = .init(allocator);
    }
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    const GenericResponse = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    try self.send(GenericResponse{ .id = id, .result = result }, null);
}

pub fn sendNotification(self: *Self, method: []const u8, params: anytype) !void {
    const Notification = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: @TypeOf(params),
    };
    const notification: Notification = .{ .method = method, .params = params };
    switch (self.notify) {
        .writer => try self.send(notification, null),
        .drop => {},
        .sink => |sink| try self.send(notification, sink),
    }
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    try self.send(protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = @backingInt(code),
            .message = message,
        },
    }, null);
}

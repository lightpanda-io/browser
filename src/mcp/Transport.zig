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
const large_response = 256 * 1024;

/// Where messages go; null drops them, as for an HTTP session between calls.
/// The HTTP worker points it at each call's job in turn, on its one thread.
sink: ?Sink,
mutex: std.Io.Mutex = .init,
aw: std.Io.Writer.Allocating,

pub const Kind = enum { response, notification };

/// Takes each message: lines on a writer (stdio), or one HTTP call's channel.
pub const Sink = struct {
    context: *anyopaque,
    /// `message` is one serialized JSON-RPC message, without a newline; borrowed.
    push: *const fn (context: *anyopaque, kind: Kind, message: []const u8) error{WriteFailed}!void,

    /// One message per line on `writer`, flushed after each.
    pub fn lines(writer: *std.Io.Writer) Sink {
        return .{ .context = writer, .push = pushLine };
    }

    fn pushLine(context: *anyopaque, _: Kind, message: []const u8) error{WriteFailed}!void {
        const writer: *std.Io.Writer = @ptrCast(@alignCast(context));
        try writer.writeAll(message);
        try writer.writeByte('\n');
        try writer.flush();
    }
};

pub fn init(allocator: std.mem.Allocator, sink: ?Sink) Self {
    return .{ .sink = sink, .aw = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.aw.deinit();
}

fn send(self: *Self, kind: Kind, message: anytype) !void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    const sink = self.sink orelse return;
    self.aw.clearRetainingCapacity();
    try std.json.Stringify.value(message, .{ .emit_null_optional_fields = false }, &self.aw.writer);
    try sink.push(sink.context, kind, self.aw.writer.buffered());

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
    try self.send(.response, GenericResponse{ .id = id, .result = result });
}

pub fn sendNotification(self: *Self, method: []const u8, params: anytype) !void {
    const Notification = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: @TypeOf(params),
    };
    try self.send(.notification, Notification{ .method = method, .params = params });
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    try self.send(.response, protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = @backingInt(code),
            .message = message,
        },
    });
}

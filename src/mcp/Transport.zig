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

//! Stdio JSON-RPC writer for the browser-tools MCP server
//! (`mcp/Server.zig`).

const std = @import("std");
const lp = @import("lightpanda");
const protocol = @import("protocol.zig");

const Self = @This();

writer: *std.Io.Writer,
mutex: std.Io.Mutex = .init,
aw: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Self {
    return .{ .writer = writer, .aw = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.aw.deinit();
}

/// Point subsequent responses at a different sink. The HTTP transport uses
/// this to capture each request's response into its own buffer; safe because
/// the browser worker retargets and writes on a single thread.
pub fn retarget(self: *Self, writer: *std.Io.Writer) void {
    self.writer = writer;
}

pub fn sendResponse(self: *Self, response: anytype) !void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    self.aw.clearRetainingCapacity();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &self.aw.writer);
    try self.aw.writer.writeByte('\n');
    try self.writer.writeAll(self.aw.writer.buffered());
    try self.writer.flush();
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    const GenericResponse = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    try self.sendResponse(GenericResponse{ .id = id, .result = result });
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    try self.sendResponse(protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = @intFromEnum(code),
            .message = message,
        },
    });
}

//! Stdio JSON-RPC writer shared between the browser-tools MCP server
//! (`mcp/Server.zig`) and the agent-tool MCP server
//! (`agent/McpServer.zig`).

const std = @import("std");
const protocol = @import("protocol.zig");

const Self = @This();

writer: *std.io.Writer,
mutex: std.Thread.Mutex = .{},
aw: std.io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, writer: *std.io.Writer) Self {
    return .{ .writer = writer, .aw = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.aw.deinit();
}

pub fn sendResponse(self: *Self, response: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

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

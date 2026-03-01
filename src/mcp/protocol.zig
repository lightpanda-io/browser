const std = @import("std");

pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: ?std.json.Value = null,
    @"error": ?Error = null,
};

pub const Error = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};

// Core MCP Types mapping to official specification
pub const InitializeRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    method: []const u8 = "initialize",
    params: InitializeParams,
};

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: Capabilities,
    clientInfo: Implementation,
};

pub const Capabilities = struct {
    experimental: ?std.json.Value = null,
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
};

pub const RootsCapability = struct {
    listChanged: ?bool = null,
};

pub const SamplingCapability = struct {};

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
};

pub const ServerCapabilities = struct {
    experimental: ?std.json.Value = null,
    logging: ?LoggingCapability = null,
    prompts: ?PromptsCapability = null,
    resources: ?ResourcesCapability = null,
    tools: ?ToolsCapability = null,
};

pub const LoggingCapability = struct {};
pub const PromptsCapability = struct {
    listChanged: ?bool = null,
};
pub const ResourcesCapability = struct {
    subscribe: ?bool = null,
    listChanged: ?bool = null,
};
pub const ToolsCapability = struct {
    listChanged: ?bool = null,
};

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const JsonEscapingWriter = struct {
    inner_writer: *std.Io.Writer,
    writer: std.Io.Writer,

    pub fn init(inner_writer: *std.Io.Writer) JsonEscapingWriter {
        return .{
            .inner_writer = inner_writer,
            .writer = .{
                .vtable = &vtable,
                .buffer = &.{},
            },
        };
    }

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *JsonEscapingWriter = @alignCast(@fieldParentPtr("writer", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            std.json.Stringify.encodeJsonStringChars(slice, .{}, self.inner_writer) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            std.json.Stringify.encodeJsonStringChars(pattern, .{}, self.inner_writer) catch return error.WriteFailed;
            total += pattern.len;
        }
        return total;
    }
};

const testing = @import("../testing.zig");

test "protocol request parsing" {
    const raw_json =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "initialize",
        \\  "params": {
        \\    "protocolVersion": "2024-11-05",
        \\    "capabilities": {},
        \\    "clientInfo": {
        \\      "name": "test-client",
        \\      "version": "1.0.0"
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Request, testing.allocator, raw_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const req = parsed.value;
    try testing.expectString("2.0", req.jsonrpc);
    try testing.expectString("initialize", req.method);
    try testing.expect(req.id.? == .integer);
    try testing.expectEqual(@as(i64, 1), req.id.?.integer);
    try testing.expect(req.params != null);

    // Test nested parsing of InitializeParams
    const init_params = try std.json.parseFromValue(InitializeParams, testing.allocator, req.params.?, .{ .ignore_unknown_fields = true });
    defer init_params.deinit();

    try testing.expectString("2024-11-05", init_params.value.protocolVersion);
    try testing.expectString("test-client", init_params.value.clientInfo.name);
    try testing.expectString("1.0.0", init_params.value.clientInfo.version);
}

test "protocol response formatting" {
    const response = Response{
        .id = .{ .integer = 42 },
        .result = .{ .string = "success" },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);

    try testing.expectString("{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":\"success\"}", aw.written());
}

test "protocol error formatting" {
    const response = Response{
        .id = .{ .string = "abc" },
        .@"error" = .{
            .code = -32601,
            .message = "Method not found",
        },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);

    try testing.expectString("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", aw.written());
}

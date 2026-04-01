const std = @import("std");

pub const Version = enum {
    @"2024-11-05",
    @"2025-03-26",
    @"2025-06-18",
    @"2025-11-25",

    pub const default: Version = .@"2024-11-05";
};

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

pub const ErrorCode = enum(i64) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    PageNotLoaded = -32604,
    NotFound = -32605,
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
    inputSchema: []const u8,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.description) |d| {
            try jw.objectField("description");
            try jw.write(d);
        }
        try jw.objectField("inputSchema");
        _ = try jw.beginWriteRaw();
        try jw.writer.writeAll(self.inputSchema);
        jw.endWriteRaw();
        try jw.endObject();
    }
};

pub fn minify(comptime json: []const u8) []const u8 {
    @setEvalBranchQuota(100000);
    return comptime blk: {
        var res: []const u8 = "";
        var in_string = false;
        var escaped = false;
        for (json) |c| {
            if (in_string) {
                res = res ++ [1]u8{c};
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
            } else {
                switch (c) {
                    ' ', '\n', '\r', '\t' => continue,
                    '"' => {
                        in_string = true;
                        res = res ++ [1]u8{c};
                    },
                    else => res = res ++ [1]u8{c},
                }
            }
        }
        break :blk res;
    };
}

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub fn TextContent(comptime T: type) type {
    return struct {
        type: []const u8 = "text",
        text: T,
    };
}

pub fn CallToolResult(comptime T: type) type {
    return struct {
        content: []const TextContent(T),
        isError: bool = false,
    };
}

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

test "MCP.protocol - request parsing" {
    defer testing.reset();
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

    const parsed = try std.json.parseFromSlice(Request, testing.arena_allocator, raw_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const req = parsed.value;
    try testing.expectString("2.0", req.jsonrpc);
    try testing.expectString("initialize", req.method);
    try testing.expect(req.id.? == .integer);
    try testing.expectEqual(@as(i64, 1), req.id.?.integer);
    try testing.expect(req.params != null);

    // Test nested parsing of InitializeParams
    const init_params = try std.json.parseFromValue(InitializeParams, testing.arena_allocator, req.params.?, .{ .ignore_unknown_fields = true });
    defer init_params.deinit();

    try testing.expectString("2024-11-05", init_params.value.protocolVersion);
    try testing.expectString("test-client", init_params.value.clientInfo.name);
    try testing.expectString("1.0.0", init_params.value.clientInfo.version);
}

test "MCP.protocol - ping request parsing" {
    defer testing.reset();
    const raw_json =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": "123",
        \\  "method": "ping"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Request, testing.arena_allocator, raw_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const req = parsed.value;
    try testing.expectString("2.0", req.jsonrpc);
    try testing.expectString("ping", req.method);
    try testing.expect(req.id.? == .string);
    try testing.expectString("123", req.id.?.string);
    try testing.expectEqual(null, req.params);
}

test "MCP.protocol - response formatting" {
    defer testing.reset();
    const response = Response{
        .id = .{ .integer = 42 },
        .result = .{ .string = "success" },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);

    try testing.expectString("{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":\"success\"}", aw.written());
}

test "MCP.protocol - error formatting" {
    defer testing.reset();
    const response = Response{
        .id = .{ .string = "abc" },
        .@"error" = .{
            .code = @intFromEnum(ErrorCode.MethodNotFound),
            .message = "Method not found",
        },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);

    try testing.expectString("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", aw.written());
}

test "MCP.protocol - JsonEscapingWriter" {
    defer testing.reset();
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer aw.deinit();

    var escaping_writer = JsonEscapingWriter.init(&aw.writer);

    // test newlines and quotes
    try escaping_writer.writer.writeAll("hello\n\"world\"");

    // the writer outputs escaped string chars without surrounding quotes
    try testing.expectString("hello\\n\\\"world\\\"", aw.written());
}

test "MCP.protocol - Tool serialization" {
    defer testing.reset();
    const t = Tool{
        .name = "test",
        .inputSchema = minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "foo": { "type": "string" }
            \\  }
            \\}
        ),
    };

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer aw.deinit();

    try std.json.Stringify.value(t, .{}, &aw.writer);

    try testing.expectString("{\"name\":\"test\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"foo\":{\"type\":\"string\"}}}}", aw.written());
}

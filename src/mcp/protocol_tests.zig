const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");

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

    const parsed = try std.json.parseFromSlice(protocol.Request, testing.allocator, raw_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const req = parsed.value;
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("initialize", req.method);
    try testing.expect(req.id == .integer);
    try testing.expectEqual(@as(i64, 1), req.id.integer);
    try testing.expect(req.params != null);

    // Test nested parsing of InitializeParams
    const init_params = try std.json.parseFromValue(protocol.InitializeParams, testing.allocator, req.params.?, .{ .ignore_unknown_fields = true });
    defer init_params.deinit();

    try testing.expectEqualStrings("2024-11-05", init_params.value.protocolVersion);
    try testing.expectEqualStrings("test-client", init_params.value.clientInfo.name);
    try testing.expectEqualStrings("1.0.0", init_params.value.clientInfo.version);
}

test "protocol response formatting" {
    const response = protocol.Response{
        .id = .{ .integer = 42 },
        .result = .{ .string = "success" },
    };

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);

    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":\"success\"}", aw.written());
}

test "protocol error formatting" {
    const response = protocol.Response{
        .id = .{ .string = "abc" },
        .@"error" = .{
            .code = -32601,
            .message = "Method not found",
        },
    };

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);

    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", aw.written());
}

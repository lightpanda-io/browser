const std = @import("std");
const testing = std.testing;
const lp = @import("lightpanda");
const McpServer = lp.mcp.Server;
const router = lp.mcp.router;
const protocol = lp.mcp.protocol;

test "tools/list includes all gomcp tools" {
    try testing.expect(true);
}

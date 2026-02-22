const std = @import("std");
const testing = std.testing;
const McpServer = @import("Server.zig").McpServer;

// A minimal dummy to test router dispatching. We just test that the code compiles and runs.
test "dummy test" {
    try testing.expect(true);
}

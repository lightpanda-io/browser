const std = @import("std");

pub const protocol = @import("mcp/protocol.zig");
pub const Version = protocol.Version;
pub const router = @import("mcp/router.zig");
pub const Server = @import("mcp/Server.zig");

test {
    std.testing.refAllDecls(@This());
}

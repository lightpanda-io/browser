const std = @import("std");

pub const protocol = @import("mcp/protocol.zig");
pub const Version = protocol.Version;
pub const router = @import("mcp/router.zig");
pub const Server = @import("mcp/Server.zig");
pub const HttpServer = @import("mcp/HttpServer.zig");

test {
    // Pull private WebDriver router tests into the root suite.
    _ = @import("mcp/webdriver.zig");
    std.testing.refAllDecls(@This());
}

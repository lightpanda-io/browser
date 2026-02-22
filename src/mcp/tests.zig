const std = @import("std");

pub const protocol_tests = @import("protocol_tests.zig");
pub const router_tests = @import("router_tests.zig");

test {
    std.testing.refAllDecls(@This());
}

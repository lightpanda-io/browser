const std = @import("std");
const parser = @import("netsurf.zig");

pub const UserContext = struct {
    document: ?*parser.DocumentHTML,
};

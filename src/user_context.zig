const std = @import("std");
const parser = @import("netsurf");
const Client = @import("async/Client.zig");

pub const UserContext = struct {
    document: *parser.DocumentHTML,
    httpClient: *Client,
};

const std = @import("std");
const parser = @import("netsurf");
const Client = @import("http/client.zig").Client;

pub const UserContext = struct {
    document: *parser.DocumentHTML,
    http_client: *Client,
};

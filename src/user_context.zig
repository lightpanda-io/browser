const std = @import("std");
const parser = @import("netsurf");
const Client = @import("http/async/main.zig").Client;

pub const UserContext = struct {
    document: *parser.DocumentHTML,
    httpClient: *Client,
};

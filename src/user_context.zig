const std = @import("std");
const parser = @import("netsurf");
const storage = @import("storage/storage.zig");
const Client = @import("http/client.zig").Client;

pub const UserContext = struct {
    http_client: *Client,
    uri: std.Uri,
    document: *parser.DocumentHTML,
    cookie_jar: *storage.CookieJar,
};

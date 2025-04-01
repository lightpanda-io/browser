const std = @import("std");
const parser = @import("netsurf");
const storage = @import("storage/storage.zig");
const Client = @import("http/client.zig").Client;
const Renderer = @import("browser/browser.zig").Renderer;

pub const UserContext = struct {
    uri: std.Uri,
    http_client: *Client,
    document: *parser.DocumentHTML,
    cookie_jar: *storage.CookieJar,
    renderer: *Renderer,
};

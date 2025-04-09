const std = @import("std");
const parser = @import("netsurf");
const URL = @import("url.zig").URL;
const storage = @import("storage/storage.zig");
const Client = @import("http/client.zig").Client;
const Renderer = @import("browser/browser.zig").Renderer;

pub const UserContext = struct {
    url: *const URL,
    http_client: *Client,
    document: *parser.DocumentHTML,
    cookie_jar: *storage.CookieJar,
    renderer: *Renderer,
};

const std = @import("std");

const parser = @import("netsurf.zig");
const URL = @import("../url.zig").URL;
const js = @import("../runtime/js.zig");
const storage = @import("storage/storage.zig");
const generate = @import("../runtime/generate.zig");
const Loop = @import("../runtime/loop.zig").Loop;
const HttpClient = @import("../http/client.zig").Client;
const Renderer = @import("browser.zig").Renderer;

const Interfaces = generate.Tuple(.{
    @import("console/console.zig").Console,
    @import("dom/dom.zig").Interfaces,
    @import("events/event.zig").Interfaces,
    @import("html/html.zig").Interfaces,
    @import("iterator/iterator.zig").Interfaces,
    @import("storage/storage.zig").Interfaces,
    @import("url/url.zig").Interfaces,
    @import("xhr/xhr.zig").Interfaces,
    @import("xmlserializer/xmlserializer.zig").Interfaces,
});

pub const Callback = Env.Callback;
pub const Env = js.Env(*SessionState, Interfaces{});

pub const SessionState = struct {
    loop: *Loop,
    url: *const URL,
    renderer: *Renderer,
    arena: std.mem.Allocator,
    http_client: *HttpClient,
    cookie_jar: *storage.CookieJar,
    document: ?*parser.DocumentHTML,
};

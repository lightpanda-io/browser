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
    @import("crypto/crypto.zig").Crypto,
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

pub const JsThis = Env.JsThis;
pub const JsObject = Env.JsObject;
pub const Callback = Env.Callback;
pub const Env = js.Env(*SessionState, Interfaces{});
pub const Global = @import("html/window.zig").Window;

pub const SessionState = struct {
    loop: *Loop,
    url: *const URL,
    renderer: *Renderer,
    arena: std.mem.Allocator,
    http_client: *HttpClient,
    cookie_jar: *storage.CookieJar,
    document: ?*parser.DocumentHTML,

    // dangerous, but set by the JS framework
    // shorter-lived than the arena above, which
    // exists for the entire rendering of the page
    call_arena: std.mem.Allocator = undefined,
};

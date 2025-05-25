const std = @import("std");

const parser = @import("netsurf.zig");
const URL = @import("../url.zig").URL;
const js = @import("../runtime/js.zig");
const storage = @import("storage/storage.zig");
const generate = @import("../runtime/generate.zig");
const Renderer = @import("renderer.zig").Renderer;
const Loop = @import("../runtime/loop.zig").Loop;
const RequestFactory = @import("../http/client.zig").RequestFactory;

const WebApis = struct {
    // Wrapped like this for debug ergonomics.
    // When we create our Env, a few lines down, we define it as:
    //   pub const Env = js.Env(*SessionState, WebApis);
    //
    // If there's a compile time error witht he Env, it's type will be readable,
    // i.e.: runtime.js.Env(*browser.env.SessionState, browser.env.WebApis)
    //
    // But if we didn't wrap it in the struct, like we once didn't, and defined
    // env as:
    //   pub const Env = js.Env(*SessionState, Interfaces);
    //
    // Because Interfaces is an anynoumous type, it doesn't have a friendly name
    // and errors would be something like:
    //   runtime.js.Env(*browser.env.SessionState, .{...A HUNDRED TYPES...})
    pub const Interfaces = generate.Tuple(.{
        @import("crypto/crypto.zig").Crypto,
        @import("console/console.zig").Console,
        @import("cssom/css_style_declaration.zig").Interfaces,
        @import("dom/dom.zig").Interfaces,
        @import("encoding/text_encoder.zig").Interfaces,
        @import("events/event.zig").Interfaces,
        @import("html/html.zig").Interfaces,
        @import("iterator/iterator.zig").Interfaces,
        @import("storage/storage.zig").Interfaces,
        @import("url/url.zig").Interfaces,
        @import("xhr/xhr.zig").Interfaces,
        @import("xhr/form_data.zig").Interfaces,
        @import("xmlserializer/xmlserializer.zig").Interfaces,
    });
};

pub const JsThis = Env.JsThis;
pub const JsObject = Env.JsObject;
pub const Callback = Env.Callback;
pub const Env = js.Env(*SessionState, WebApis);

const Window = @import("html/window.zig").Window;
pub const Global = Window;

pub const SessionState = struct {
    loop: *Loop,
    url: *const URL,
    window: *Window,
    renderer: *Renderer,
    arena: std.mem.Allocator,
    cookie_jar: *storage.CookieJar,
    request_factory: RequestFactory,

    // dangerous, but set by the JS framework
    // shorter-lived than the arena above, which
    // exists for the entire rendering of the page
    call_arena: std.mem.Allocator = undefined,

    pub fn getOrCreateNodeWrapper(self: *SessionState, comptime T: type, node: *parser.Node) !*T {
        if (try self.getNodeWrapper(T, node)) |wrap| {
            return wrap;
        }

        const wrap = try self.arena.create(T);
        wrap.* = T{};

        parser.nodeSetEmbedderData(node, wrap);
        return wrap;
    }

    pub fn getNodeWrapper(_: *SessionState, comptime T: type, node: *parser.Node) !?*T {
        if (parser.nodeGetEmbedderData(node)) |wrap| {
            return @alignCast(@ptrCast(wrap));
        }
        return null;
    }
};

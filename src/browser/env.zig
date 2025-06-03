const std = @import("std");

const Page = @import("page.zig").Page;
const js = @import("../runtime/js.zig");
const generate = @import("../runtime/generate.zig");

const WebApis = struct {
    // Wrapped like this for debug ergonomics.
    // When we create our Env, a few lines down, we define it as:
    //   pub const Env = js.Env(*Page, WebApis);
    //
    // If there's a compile time error witht he Env, it's type will be readable,
    // i.e.: runtime.js.Env(*browser.env.Page, browser.env.WebApis)
    //
    // But if we didn't wrap it in the struct, like we once didn't, and defined
    // env as:
    //   pub const Env = js.Env(*Page, Interfaces);
    //
    // Because Interfaces is an anynoumous type, it doesn't have a friendly name
    // and errors would be something like:
    //   runtime.js.Env(*browser.Page, .{...A HUNDRED TYPES...})
    pub const Interfaces = generate.Tuple(.{
        @import("crypto/crypto.zig").Crypto,
        @import("console/console.zig").Console,
        @import("cssom/cssom.zig").Interfaces,
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
        @import("webcomponents/webcomponents.zig").Interfaces,
    });
};

pub const JsThis = Env.JsThis;
pub const JsObject = Env.JsObject;
pub const Function = Env.Function;
pub const Env = js.Env(*Page, WebApis);
pub const Global = @import("html/window.zig").Window;

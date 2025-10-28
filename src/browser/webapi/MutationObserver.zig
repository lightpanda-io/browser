const js = @import("../js/js.zig");

// @ZIGDOM (haha, bet you wish you hadn't opened this file)
// puppeteer's startup script creates a MutationObserver, even if it doesn't use
// it in simple scripts. This not-even-a-skeleton is required for puppeteer/cdp.js
// to run
const MutationObserver = @This();

pub fn init() MutationObserver {
    return .{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MutationObserver);

    pub const Meta = struct {
        pub const name = "MutationObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(MutationObserver.init, .{});
};

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const FontFaceSet = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

pub fn init(page: *Page) !*FontFaceSet {
    return page._factory.create(FontFaceSet{});
}

// FontFaceSet.ready - returns an already-resolved Promise.
// In a headless browser there is no font loading, so fonts are always ready.
pub fn getReady(_: *FontFaceSet, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise({});
}

pub fn getStatus(_: *const FontFaceSet) []const u8 {
    return "loaded";
}

pub fn getSize(_: *const FontFaceSet) u32 {
    return 0;
}

// check(font, text?) - always true; headless has no real fonts to check.
pub fn check(_: *const FontFaceSet, font: []const u8) bool {
    _ = font;
    return true;
}

// load(font, text?) - resolves immediately with an empty array.
pub fn load(_: *FontFaceSet, font: []const u8, page: *Page) !js.Promise {
    _ = font;
    return page.js.local.?.resolvePromise({});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const status = bridge.accessor(FontFaceSet.getStatus, null, .{});
    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}

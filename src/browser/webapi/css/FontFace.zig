const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const FontFace = @This();

_family: []const u8,
_source: []const u8,
_style: []const u8,
_weight: []const u8,
_stretch: []const u8,
_unicode_range: []const u8,
_variant: []const u8,
_feature_settings: []const u8,
_display: []const u8,

pub fn init(family: []const u8, source: []const u8, page: *Page) !*FontFace {
    return page._factory.create(FontFace{
        ._family = try page.dupeString(family),
        ._source = try page.dupeString(source),
        ._style = "normal",
        ._weight = "normal",
        ._stretch = "normal",
        ._unicode_range = "U+0-10FFFF",
        ._variant = "normal",
        ._feature_settings = "normal",
        ._display = "auto",
    });
}

pub fn getFamily(self: *const FontFace) []const u8 {
    return self._family;
}

pub fn getStyle(self: *const FontFace) []const u8 {
    return self._style;
}

pub fn getWeight(self: *const FontFace) []const u8 {
    return self._weight;
}

pub fn getStretch(self: *const FontFace) []const u8 {
    return self._stretch;
}

pub fn getUnicodeRange(self: *const FontFace) []const u8 {
    return self._unicode_range;
}

pub fn getVariant(self: *const FontFace) []const u8 {
    return self._variant;
}

pub fn getFeatureSettings(self: *const FontFace) []const u8 {
    return self._feature_settings;
}

pub fn getDisplay(self: *const FontFace) []const u8 {
    return self._display;
}

// load() - resolves immediately; headless browser has no real font loading.
pub fn load(_: *FontFace, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise({});
}

// loaded - returns an already-resolved Promise.
pub fn getLoaded(_: *FontFace, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise({});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFace);

    pub const Meta = struct {
        pub const name = "FontFace";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FontFace.init, .{});
    pub const family = bridge.accessor(FontFace.getFamily, null, .{});
    pub const style = bridge.accessor(FontFace.getStyle, null, .{});
    pub const weight = bridge.accessor(FontFace.getWeight, null, .{});
    pub const stretch = bridge.accessor(FontFace.getStretch, null, .{});
    pub const unicodeRange = bridge.accessor(FontFace.getUnicodeRange, null, .{});
    pub const variant = bridge.accessor(FontFace.getVariant, null, .{});
    pub const featureSettings = bridge.accessor(FontFace.getFeatureSettings, null, .{});
    pub const display = bridge.accessor(FontFace.getDisplay, null, .{});
    pub const status = bridge.property("loaded", .{ .template = false, .readonly = true });
    pub const loaded = bridge.accessor(FontFace.getLoaded, null, .{});
    pub const load = bridge.function(FontFace.load, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFace" {
    try testing.htmlRunner("css/font_face.html", .{});
}

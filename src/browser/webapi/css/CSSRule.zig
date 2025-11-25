const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const CSSRule = @This();

pub const Type = enum(u16) {
    style = 1,
    charset = 2,
    import = 3,
    media = 4,
    font_face = 5,
    page = 6,
    keyframes = 7,
    keyframe = 8,
    margin = 9,
    namespace = 10,
    counter_style = 11,
    supports = 12,
    document = 13,
    font_feature_values = 14,
    viewport = 15,
    region_style = 16,
};

_type: Type,

pub fn init(rule_type: Type, page: *Page) !*CSSRule {
    return page._factory.create(CSSRule{
        ._type = rule_type,
    });
}

pub fn getType(self: *const CSSRule) u16 {
    return @intFromEnum(self._type);
}

pub fn getCssText(self: *const CSSRule, page: *Page) []const u8 {
    _ = self;
    _ = page;
    return "";
}

pub fn setCssText(self: *CSSRule, text: []const u8, page: *Page) !void {
    _ = self;
    _ = text;
    _ = page;
}

pub fn getParentRule(self: *const CSSRule) ?*CSSRule {
    _ = self;
    return null;
}

pub fn getParentStyleSheet(self: *const CSSRule) ?*CSSRule {
    _ = self;
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSRule);

    pub const Meta = struct {
        pub const name = "CSSRule";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const STYLE_RULE = 1;
    pub const CHARSET_RULE = 2;
    pub const IMPORT_RULE = 3;
    pub const MEDIA_RULE = 4;
    pub const FONT_FACE_RULE = 5;
    pub const PAGE_RULE = 6;
    pub const KEYFRAMES_RULE = 7;
    pub const KEYFRAME_RULE = 8;
    pub const MARGIN_RULE = 9;
    pub const NAMESPACE_RULE = 10;
    pub const COUNTER_STYLE_RULE = 11;
    pub const SUPPORTS_RULE = 12;
    pub const DOCUMENT_RULE = 13;
    pub const FONT_FEATURE_VALUES_RULE = 14;
    pub const VIEWPORT_RULE = 15;
    pub const REGION_STYLE_RULE = 16;

    pub const @"type" = bridge.accessor(CSSRule.getType, null, .{});
    pub const cssText = bridge.accessor(CSSRule.getCssText, CSSRule.setCssText, .{});
    pub const parentRule = bridge.accessor(CSSRule.getParentRule, null, .{});
    pub const parentStyleSheet = bridge.accessor(CSSRule.getParentStyleSheet, null, .{});
};

const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const CSSStyleRule = @import("CSSStyleRule.zig");

const CSSRule = @This();

pub const Type = union(enum) {
    style: *CSSStyleRule,
    charset: void,
    import: void,
    media: void,
    font_face: void,
    frame: void,
    keyframes: void,
    keyframe: void,
    margin: void,
    namespace: void,
    counter_style: void,
    supports: void,
    document: void,
    font_feature_values: void,
    viewport: void,
    region_style: void,
};

_type: Type,

pub fn as(self: *CSSRule, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *CSSRule, comptime T: type) ?*T {
    switch (self._type) {
        .style => |r| return if (T == CSSStyleRule) r else null,
        else => return null,
    }
}

pub fn init(rule_type: Type, frame: *Frame) !*CSSRule {
    return frame._factory.create(CSSRule{
        ._type = rule_type,
    });
}

pub fn getType(self: *const CSSRule) u16 {
    return @as(u16, @intFromEnum(std.meta.activeTag(self._type))) + 1;
}

pub fn getCssText(_: *const CSSRule, _: *Frame) []const u8 {
    return "";
}

pub fn getParentRule(_: *const CSSRule) ?*CSSRule {
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
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
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
    pub const cssText = bridge.accessor(CSSRule.getCssText, null, .{});
    pub const parentRule = bridge.accessor(CSSRule.getParentRule, null, .{});
    pub const parentStyleSheet = bridge.accessor(CSSRule.getParentStyleSheet, null, .{});
};

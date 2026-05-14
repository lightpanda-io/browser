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
/// Original source text for at-rules (`@keyframes`, `@media`, ...). Empty
/// for `.style` because `CSSStyleRule.getCssText` constructs its own
/// serialization from selector + declarations. The bridge dispatches the
/// most-derived `cssText` accessor (CSSStyleRule's), so this field only
/// surfaces for opaque at-rule placeholders. See lightpanda-io/browser#2459.
_text: []const u8 = "",

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

/// Construct an at-rule placeholder with stored source text. Used when an
/// `@keyframes` / `@media` / etc. lands via `insertRule` or `replaceSync`
/// so that JS-side reads via `cssRules` see the rule (matching length and
/// `cssText`) without the CSS engine actually applying it.
pub fn initAtRule(rule_type: Type, text: []const u8, frame: *Frame) !*CSSRule {
    return frame._factory.create(CSSRule{
        ._type = rule_type,
        ._text = try frame.dupeString(text),
    });
}

pub fn getType(self: *const CSSRule) u16 {
    return @as(u16, @intFromEnum(std.meta.activeTag(self._type))) + 1;
}

pub fn getCssText(self: *const CSSRule, _: *Frame) []const u8 {
    return self._text;
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

    // Spec rule-type constants. Wrapped with `bridge.property(.template)` so
    // they're exposed on the JS-side `CSSRule` constructor (e.g.
    // `CSSRule.KEYFRAMES_RULE === 7`). Without the wrapping these are plain
    // Zig declarations that never reach JS, and code reading them gets
    // `undefined`.
    pub const STYLE_RULE = bridge.property(1, .{ .template = true });
    pub const CHARSET_RULE = bridge.property(2, .{ .template = true });
    pub const IMPORT_RULE = bridge.property(3, .{ .template = true });
    pub const MEDIA_RULE = bridge.property(4, .{ .template = true });
    pub const FONT_FACE_RULE = bridge.property(5, .{ .template = true });
    pub const PAGE_RULE = bridge.property(6, .{ .template = true });
    pub const KEYFRAMES_RULE = bridge.property(7, .{ .template = true });
    pub const KEYFRAME_RULE = bridge.property(8, .{ .template = true });
    pub const MARGIN_RULE = bridge.property(9, .{ .template = true });
    pub const NAMESPACE_RULE = bridge.property(10, .{ .template = true });
    pub const COUNTER_STYLE_RULE = bridge.property(11, .{ .template = true });
    pub const SUPPORTS_RULE = bridge.property(12, .{ .template = true });
    pub const DOCUMENT_RULE = bridge.property(13, .{ .template = true });
    pub const FONT_FEATURE_VALUES_RULE = bridge.property(14, .{ .template = true });
    pub const VIEWPORT_RULE = bridge.property(15, .{ .template = true });
    pub const REGION_STYLE_RULE = bridge.property(16, .{ .template = true });

    pub const @"type" = bridge.accessor(CSSRule.getType, null, .{});
    pub const cssText = bridge.accessor(CSSRule.getCssText, null, .{});
    pub const parentRule = bridge.accessor(CSSRule.getParentRule, null, .{});
    pub const parentStyleSheet = bridge.accessor(CSSRule.getParentStyleSheet, null, .{});
};

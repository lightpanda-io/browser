const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const CSSRule = @import("CSSRule.zig");

const CSSRuleList = @This();

_rules: []*CSSRule = &.{},

pub fn init(page: *Page) !*CSSRuleList {
    return page._factory.create(CSSRuleList{});
}

pub fn length(self: *const CSSRuleList) u32 {
    return @intCast(self._rules.len);
}

pub fn item(self: *const CSSRuleList, index: usize) ?*CSSRule {
    if (index >= self._rules.len) {
        return null;
    }
    return self._rules[index];
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSRuleList);

    pub const Meta = struct {
        pub const name = "CSSRuleList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(CSSRuleList.length, null, .{});
    pub const @"[]" = bridge.indexed(CSSRuleList.item, null, .{ .null_as_undefined = true });
};

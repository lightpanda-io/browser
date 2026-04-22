const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const CSSRule = @import("CSSRule.zig");

const CSSRuleList = @This();

_rules: std.ArrayList(*CSSRule) = .empty,

pub fn init(frame: *Frame) !*CSSRuleList {
    return frame._factory.create(CSSRuleList{});
}

pub fn length(self: *const CSSRuleList) u32 {
    return @intCast(self._rules.items.len);
}

pub fn item(self: *const CSSRuleList, index: usize) ?*CSSRule {
    if (index >= self._rules.items.len) {
        return null;
    }
    return self._rules.items[index];
}

pub fn insert(self: *CSSRuleList, index: u32, rule: *CSSRule, frame: *Frame) !void {
    if (index > self._rules.items.len) {
        return error.IndexSizeError;
    }
    try self._rules.insert(frame.arena, index, rule);
}

pub fn remove(self: *CSSRuleList, index: u32) !void {
    if (index >= self._rules.items.len) {
        return error.IndexSizeError;
    }
    _ = self._rules.orderedRemove(index);
}

pub fn clear(self: *CSSRuleList) void {
    self._rules.clearRetainingCapacity();
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

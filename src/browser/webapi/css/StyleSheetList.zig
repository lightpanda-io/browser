const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");

const StyleSheetList = @This();

_sheets: std.ArrayList(*CSSStyleSheet) = .empty,

pub fn init(page: *Page) !*StyleSheetList {
    return page._factory.create(StyleSheetList{});
}

pub fn length(self: *const StyleSheetList) u32 {
    return @intCast(self._sheets.items.len);
}

pub fn item(self: *const StyleSheetList, index: usize) ?*CSSStyleSheet {
    if (index >= self._sheets.items.len) return null;
    return self._sheets.items[index];
}

pub fn add(self: *StyleSheetList, sheet: *CSSStyleSheet, page: *Page) !void {
    try self._sheets.append(page.arena, sheet);
}

pub fn remove(self: *StyleSheetList, sheet: *CSSStyleSheet) void {
    for (self._sheets.items, 0..) |s, i| {
        if (s == sheet) {
            _ = self._sheets.orderedRemove(i);
            return;
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StyleSheetList);

    pub const Meta = struct {
        pub const name = "StyleSheetList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(StyleSheetList.length, null, .{});
    pub const @"[]" = bridge.indexed(StyleSheetList.item, null, .{ .null_as_undefined = true });
};

const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

pub fn registerTypes() []const type {
    return &.{
        Image,
        // Factory,
    };
}

const Image = @This();
_proto: *HtmlElement,

pub fn constructor(w_: ?u32, h_: ?u32, page: *Page) !*Image {
    const node = try page.createElement(null, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&page.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe("width", w_string, page);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&page.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe("height", h_string, page);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Image) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe("src") orelse "";
}

pub fn setSrc(self: *Image, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("src", value, page);
}

pub fn getAlt(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe("alt") orelse "";
}

pub fn setAlt(self: *Image, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("alt", value, page);
}

pub fn getWidth(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe("width") orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setWidth(self: *Image, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe("width", str, page);
}

pub fn getHeight(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe("height") orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setHeight(self: *Image, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe("height", str, page);
}

pub fn getCrossOrigin(self: *const Image) ?[]const u8 {
    return self.asConstElement().getAttributeSafe("crossorigin");
}

pub fn setCrossOrigin(self: *Image, value: ?[]const u8, page: *Page) !void {
    if (value) |v| {
        return self.asElement().setAttributeSafe("crossorigin", v, page);
    }
    return self.asElement().removeAttribute("crossorigin", page);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe("loading") orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("loading", value, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{});
    pub const alt = bridge.accessor(Image.getAlt, Image.setAlt, .{});
    pub const width = bridge.accessor(Image.getWidth, Image.setWidth, .{});
    pub const height = bridge.accessor(Image.getHeight, Image.setHeight, .{});
    pub const crossOrigin = bridge.accessor(Image.getCrossOrigin, Image.setCrossOrigin, .{});
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}

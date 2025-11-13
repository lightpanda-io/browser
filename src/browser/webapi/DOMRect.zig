const DOMRect = @This();

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

_x: f64,
_y: f64,
_width: f64,
_height: f64,
_top: f64,
_right: f64,
_bottom: f64,
_left: f64,

pub fn getX(self: *DOMRect) f64 {
    return self._x;
}

pub fn getY(self: *DOMRect) f64 {
    return self._y;
}

pub fn getWidth(self: *DOMRect) f64 {
    return self._width;
}

pub fn getHeight(self: *DOMRect) f64 {
    return self._height;
}

pub fn getTop(self: *DOMRect) f64 {
    return self._top;
}

pub fn getRight(self: *DOMRect) f64 {
    return self._right;
}

pub fn getBottom(self: *DOMRect) f64 {
    return self._bottom;
}

pub fn getLeft(self: *DOMRect) f64 {
    return self._left;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMRect);

    pub const Meta = struct {
        pub const name = "DOMRect";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const x = bridge.accessor(DOMRect.getX, null, .{});
    pub const y = bridge.accessor(DOMRect.getY, null, .{});
    pub const width = bridge.accessor(DOMRect.getWidth, null, .{});
    pub const height = bridge.accessor(DOMRect.getHeight, null, .{});
    pub const top = bridge.accessor(DOMRect.getTop, null, .{});
    pub const right = bridge.accessor(DOMRect.getRight, null, .{});
    pub const bottom = bridge.accessor(DOMRect.getBottom, null, .{});
    pub const left = bridge.accessor(DOMRect.getLeft, null, .{});
};

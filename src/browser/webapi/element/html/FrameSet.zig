const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Window = @import("../../Window.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const FrameSet = @This();

_proto: *HtmlElement,

pub fn asElement(self: *FrameSet) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FrameSet) *Node {
    return self.asElement().asNode();
}

// Special-case: the "window-reflecting body element event handler set"
// (blur, error, focus, load, resize, scroll) are aliases for the Window's
// event handlers, on frameset elements just like on body elements.

// The aliased Window is the one of the element's node document's frame — not
// the caller's frame, which differs when a same-origin script reaches into
// another frame (e.g. the parent setting a handler on a child frameset).
fn reflectedWindow(self: *FrameSet, frame: *Frame) *Window {
    return self.asElement().ownerFrame(frame).window;
}

pub fn getOnBlur(self: *FrameSet, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_blur;
}
pub fn setOnBlur(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_blur = Window.getFunctionFromSetter(setter);
}

pub fn getOnError(self: *FrameSet, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_error;
}
pub fn setOnError(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_error = Window.getFunctionFromSetter(setter);
}

pub fn getOnFocus(self: *FrameSet, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_focus;
}
pub fn setOnFocus(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_focus = Window.getFunctionFromSetter(setter);
}

pub fn getOnLoad(self: *FrameSet, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_load;
}
pub fn setOnLoad(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_load = Window.getFunctionFromSetter(setter);
}

pub fn getOnResize(self: *FrameSet, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_resize;
}
pub fn setOnResize(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_resize = Window.getFunctionFromSetter(setter);
}

pub fn getOnScroll(self: *FrameSet, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_scroll;
}
pub fn setOnScroll(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_scroll = Window.getFunctionFromSetter(setter);
}

pub fn getCols(self: *FrameSet) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("cols")) orelse "";
}

pub fn setCols(self: *FrameSet, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("cols"), .wrap(value), frame);
}

pub fn getRows(self: *FrameSet) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("rows")) orelse "";
}

pub fn setRows(self: *FrameSet, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rows"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FrameSet);

    pub const Meta = struct {
        pub const name = "HTMLFrameSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cols = bridge.accessor(FrameSet.getCols, FrameSet.setCols, .{ .ce_reactions = true });
    pub const rows = bridge.accessor(FrameSet.getRows, FrameSet.setRows, .{ .ce_reactions = true });

    pub const onblur = bridge.accessor(getOnBlur, setOnBlur, .{ .null_as_undefined = false });
    pub const onerror = bridge.accessor(getOnError, setOnError, .{ .null_as_undefined = false });
    pub const onfocus = bridge.accessor(getOnFocus, setOnFocus, .{ .null_as_undefined = false });
    pub const onload = bridge.accessor(getOnLoad, setOnLoad, .{ .null_as_undefined = false });
    pub const onresize = bridge.accessor(getOnResize, setOnResize, .{ .null_as_undefined = false });
    pub const onscroll = bridge.accessor(getOnScroll, setOnScroll, .{ .null_as_undefined = false });
};

pub const Build = struct {
    const window_reflecting_attributes = [_][]const u8{
        "onblur", "onerror", "onfocus", "onload", "onresize", "onscroll",
    };

    pub fn complete(node: *Node, frame: *Frame) !void {
        const el = node.as(Element);
        const owner = node.ownerFrame(frame);
        inline for (window_reflecting_attributes) |attr| {
            if (el.getAttributeSafe(comptime .wrap(attr))) |value| {
                owner.window.setWindowReflectingHandlerFromAttribute(comptime .wrap(attr), value, owner);
            }
        }
    }

    pub fn attributeChange(el: *Element, name: String, value: String, frame: *Frame) !void {
        const owner = el.ownerFrame(frame);
        owner.window.setWindowReflectingHandlerFromAttribute(name, value.str(), owner);
    }

    pub fn attributeRemove(el: *Element, name: String, frame: *Frame) !void {
        const owner = el.ownerFrame(frame);
        owner.window.setWindowReflectingHandlerFromAttribute(name, null, owner);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Frameset" {
    try testing.htmlRunner("element/html/frameset.html", .{});
}

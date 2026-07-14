// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Window = @import("../../Window.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Body = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Body) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Body) *Node {
    return self.asElement().asNode();
}

// Special-case: the "window-reflecting body element event handler set"
// (blur, error, focus, load, resize, scroll) are aliases for the Window's
// event handlers.

// The aliased Window is the one of the element's node document's frame — not
// the caller's frame, which differs when a same-origin script reaches into
// another frame (e.g. the parent setting iframeDoc.body.onblur).
fn reflectedWindow(self: *Body, frame: *Frame) *Window {
    return self.asElement().ownerFrame(frame).window;
}

pub fn getOnBlur(self: *Body, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_blur;
}
pub fn setOnBlur(self: *Body, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_blur = Window.getFunctionFromSetter(setter);
}

pub fn getOnError(self: *Body, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_error;
}
pub fn setOnError(self: *Body, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_error = Window.getFunctionFromSetter(setter);
}

pub fn getOnFocus(self: *Body, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_focus;
}
pub fn setOnFocus(self: *Body, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_focus = Window.getFunctionFromSetter(setter);
}

pub fn getOnLoad(self: *Body, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_load;
}
pub fn setOnLoad(self: *Body, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_load = Window.getFunctionFromSetter(setter);
}

pub fn getOnResize(self: *Body, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_resize;
}
pub fn setOnResize(self: *Body, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_resize = Window.getFunctionFromSetter(setter);
}

pub fn getOnScroll(self: *Body, frame: *Frame) ?js.Function.Global {
    return self.reflectedWindow(frame)._on_scroll;
}
pub fn setOnScroll(self: *Body, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    self.reflectedWindow(frame)._on_scroll = Window.getFunctionFromSetter(setter);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Body);

    pub const Meta = struct {
        pub const name = "HTMLBodyElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

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

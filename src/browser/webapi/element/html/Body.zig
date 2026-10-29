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
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Window = @import("../../Window.zig");
const HtmlElement = @import("../Html.zig");

const Body = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Body) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Body) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Body);

    pub const Meta = struct {
        pub const name = "HTMLBodyElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Body);
    pub const vLink = reflect.stringNullToEmpty("vlink");
    pub const text = reflect.stringNullToEmpty("text");
    pub const link = reflect.stringNullToEmpty("link");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const background = reflect.string("background");
    pub const aLink = reflect.stringNullToEmpty("alink");

    pub const onblur = Window.reflectingHandlerAccessor(Body, "blur");
    pub const onerror = Window.reflectingHandlerAccessor(Body, "error");
    pub const onfocus = Window.reflectingHandlerAccessor(Body, "focus");
    pub const onload = Window.reflectingHandlerAccessor(Body, "load");
    pub const onresize = Window.reflectingHandlerAccessor(Body, "resize");
    pub const onscroll = Window.reflectingHandlerAccessor(Body, "scroll");
    // WindowEventHandlers
    pub const onafterprint = Window.reflectingHandlerAccessor(Body, "afterprint");
    pub const onbeforeprint = Window.reflectingHandlerAccessor(Body, "beforeprint");
    pub const onbeforeunload = Window.reflectingHandlerAccessor(Body, "beforeunload");
    pub const onhashchange = Window.reflectingHandlerAccessor(Body, "hashchange");
    pub const onlanguagechange = Window.reflectingHandlerAccessor(Body, "languagechange");
    pub const onmessage = Window.reflectingHandlerAccessor(Body, "message");
    pub const onmessageerror = Window.reflectingHandlerAccessor(Body, "messageerror");
    pub const onoffline = Window.reflectingHandlerAccessor(Body, "offline");
    pub const ononline = Window.reflectingHandlerAccessor(Body, "online");
    pub const onpagehide = Window.reflectingHandlerAccessor(Body, "pagehide");
    pub const onpageshow = Window.reflectingHandlerAccessor(Body, "pageshow");
    pub const onpopstate = Window.reflectingHandlerAccessor(Body, "popstate");
    pub const onrejectionhandled = Window.reflectingHandlerAccessor(Body, "rejectionhandled");
    pub const onstorage = Window.reflectingHandlerAccessor(Body, "storage");
    pub const onunhandledrejection = Window.reflectingHandlerAccessor(Body, "unhandledrejection");
    pub const onunload = Window.reflectingHandlerAccessor(Body, "unload");
};

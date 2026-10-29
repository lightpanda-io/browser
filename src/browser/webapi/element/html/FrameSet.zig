// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Window = @import("../../Window.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const FrameSet = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *FrameSet) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *FrameSet) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FrameSet);

    pub const Meta = struct {
        pub const name = "HTMLFrameSetElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(FrameSet);

    pub const cols = reflect.string("cols");
    pub const rows = reflect.string("rows");

    pub const onblur = Window.reflectingHandlerAccessor(FrameSet, "blur");
    pub const onerror = Window.reflectingHandlerAccessor(FrameSet, "error");
    pub const onfocus = Window.reflectingHandlerAccessor(FrameSet, "focus");
    pub const onload = Window.reflectingHandlerAccessor(FrameSet, "load");
    pub const onresize = Window.reflectingHandlerAccessor(FrameSet, "resize");
    pub const onscroll = Window.reflectingHandlerAccessor(FrameSet, "scroll");
    // WindowEventHandlers
    pub const onafterprint = Window.reflectingHandlerAccessor(FrameSet, "afterprint");
    pub const onbeforeprint = Window.reflectingHandlerAccessor(FrameSet, "beforeprint");
    pub const onbeforeunload = Window.reflectingHandlerAccessor(FrameSet, "beforeunload");
    pub const onhashchange = Window.reflectingHandlerAccessor(FrameSet, "hashchange");
    pub const onlanguagechange = Window.reflectingHandlerAccessor(FrameSet, "languagechange");
    pub const onmessage = Window.reflectingHandlerAccessor(FrameSet, "message");
    pub const onmessageerror = Window.reflectingHandlerAccessor(FrameSet, "messageerror");
    pub const onoffline = Window.reflectingHandlerAccessor(FrameSet, "offline");
    pub const ononline = Window.reflectingHandlerAccessor(FrameSet, "online");
    pub const onpagehide = Window.reflectingHandlerAccessor(FrameSet, "pagehide");
    pub const onpageshow = Window.reflectingHandlerAccessor(FrameSet, "pageshow");
    pub const onpopstate = Window.reflectingHandlerAccessor(FrameSet, "popstate");
    pub const onrejectionhandled = Window.reflectingHandlerAccessor(FrameSet, "rejectionhandled");
    pub const onstorage = Window.reflectingHandlerAccessor(FrameSet, "storage");
    pub const onunhandledrejection = Window.reflectingHandlerAccessor(FrameSet, "unhandledrejection");
    pub const onunload = Window.reflectingHandlerAccessor(FrameSet, "unload");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Frameset" {
    try testing.htmlRunner("element/html/frameset.html", .{});
}

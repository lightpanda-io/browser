const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Script = @This();

_proto: *HtmlElement,
_src: []const u8 = "",
_on_load: ?js.Function = null,
_on_error: ?js.Function = null,
_executed: bool = false,

pub fn asElement(self: *Script) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Script) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Script) []const u8 {
    return self._src;
}

pub fn setSrc(self: *Script, src: []const u8, page: *Page) !void {
    const element = self.asElement();
    try element.setAttributeSafe("src", src, page);
    self._src = element.getAttributeSafe("src") orelse unreachable;
    if (element.asNode().isConnected()) {
        try page.scriptAddedCallback(self);
    }
}

pub fn getOnLoad(self: *const Script) ?js.Function {
    return self._on_load;
}

pub fn setOnLoad(self: *Script, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_load = cb;
    } else {
        self._on_load = null;
    }
}

pub fn getOnError(self: *const Script) ?js.Function {
    return self._on_error;
}

pub fn setOnError(self: *Script, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_error = cb;
    } else {
        self._on_error = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Script);

    pub const Meta = struct {
        pub const name = "HTMLScriptElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const src = bridge.accessor(Script.getSrc, Script.setSrc, .{});
    pub const onload = bridge.accessor(Script.getOnLoad, Script.setOnLoad, .{});
    pub const onerorr = bridge.accessor(Script.getOnError, Script.setOnError, .{});
};

pub const Build = struct {
    pub fn complete(node: *Node, page: *Page) !void {
        const self = node.as(Script);
        const element = self.asElement();
        self._src = element.getAttributeSafe("src") orelse "";

        // @ZIGDOM
        _ = page;
        // if (element.getAttributeSafe("onload")) |on_load| {
        //     self._on_load = page.js.stringToFunction(on_load);
        // }

        // if (element.getAttributeSafe("onerror")) |on_error| {
        //     self._on_error = page.js.stringToFunction(on_error);
        // }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Script" {
    try testing.htmlRunner("element/html/script", .{});
}

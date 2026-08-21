const lp = @import("lightpanda");
const std = @import("std");
const log = lp.log;
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Image = @This();

pub const Proto = HtmlElement;

// Bumped on every src assignment. An in-flight fetch carries the value it
// was issued under; when they no longer match, a newer src has taken over
// and the older response must not fire events on this element.
_generation: u32 = 0,
// Per spec, false only while a fetch is in flight. Without
// `--load-resources image` there is never a fetch, so it never leaves true.
_complete: bool = true,

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try Frame.node_factory.createElementNS(frame, .html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Image) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    // Setting the attribute is enough: `_put` dispatches to
    // `Build.attributeChange`, which starts the load. Calling
    // `imageAddedCallback` here too would issue the request twice (the first
    // one immediately superseded, so it costs a request and shows nothing).
    // Connectivity still isn't checked — a detached `new Image()` loads.
    return self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loading")) orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

pub fn getNaturalWidth(_: *const Image) u32 {
    // this is a valid response under a number of normal conditions, but could
    // be used to detect the nature of Browser.
    return 0;
}

pub fn getNaturalHeight(_: *const Image) u32 {
    // this is a valid response under a number of normal conditions, but could
    // be used to detect the nature of Browser.
    return 0;
}

pub fn getComplete(self: *const Image) bool {
    // Per spec, complete is true when: no src/srcset, src is empty, the
    // image is fully available, or the image is broken with no pending
    // request. Every one of those is "no fetch in flight", which is exactly
    // what `_complete` tracks. Without `--load-resources image` nothing ever
    // clears it.
    return self._complete;
}

/// The one funnel for "this element's src became current": parser-created
/// images (`Build.created`), `img.src = ...` (`setSrc`) and
/// `setAttribute("src", ...)` (`Build.attributeChange`) all land here.
pub fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger a load event
    // or start fetching a resource.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();
    // Exit if src not set.
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return;
    if (src.len == 0) return;

    // If image loading not desired, we just do fake "load" event.
    if (frame._session.load_resources.image == false) {
        return frame.queueLoad(Factory.protoOf(self));
    }

    // A fetch still in flight for the previous src is stale as of right now,
    // and this is the only place that knows it. Wrapping is fine: colliding
    // needs a request to still be in flight 2^32 src assignments later, which
    // outlives any transfer timeout by several orders of magnitude.
    self._generation +%= 1;

    // Deliberately not propagated. `newRequest` is declared `anyerror`, and
    // this runs on DOM mutation paths with narrow declared error sets
    // (`Node.cloneNode`'s `CloneError`, for one). Failing to even issue the
    // request is the same observable outcome as the request failing, so
    // report it the same way — `loadImage` has already unwound `_complete`
    // and the pending-load slot by the time it returns an error.
    frame.loadImage(self, src) catch |err| {
        log.warn(.http, "image fetch", .{ .err = err, .src = src });
        // On failure, queue "error" event.
        return frame.queueElementEvent(Factory.protoOf(self), .@"error");
    };
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
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Image.getSrc, null, .{});
    pub const alt = reflect.string("alt");
    pub const width = reflect.unsignedLong("width", .{});
    pub const height = reflect.unsignedLong("height", .{});
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{ .ce_reactions = true });
    const reflect = Element.Reflect(Image);
    pub const srcset = reflect.string("srcset");
    pub const useMap = reflect.string("usemap");
    pub const isMap = reflect.boolean("ismap");
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const decoding = reflect.enumerated("decoding", &.{ "async", "sync", "auto" }, .{ .missing = "auto" });
    // Obsolete
    pub const name = reflect.string("name");
    pub const lowsrc = reflect.url("lowsrc");
    pub const @"align" = reflect.string("align");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const longDesc = reflect.url("longdesc");
    pub const border = reflect.stringNullToEmpty("border");

    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }

    // Removing the src leaves no request to make, but any in-flight one still
    // has to be invalidated.
    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}

test "WebApi: HTML.Image fetch" {
    try testing.htmlRunner("element/html/image_fetch.html", .{ .load_resources = .{ .image = true } });
}

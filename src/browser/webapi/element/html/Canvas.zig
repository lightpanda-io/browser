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
const std = @import("std");
const log = lp.log;
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Blob = @import("../../Blob.zig");
const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");

const Execution = js.Execution;

const Canvas = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_cached: ?DrawingContext = null,

pub fn asElement(self: *Canvas) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
};

pub fn getContext(self: *Canvas, context_type: []const u8, frame: *Frame) !?DrawingContext {
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            const ctx = try frame._factory.create(CanvasRenderingContext2D{ ._canvas = self });
            break :blk .{ .@"2d" = ctx };
        }

        // We only stub a tiny slice of the WebGL API (getParameter,
        // getExtension, getSupportedExtensions). Real WebGL consumers like
        // Three.js immediately call createTexture/createBuffer/etc. and
        // throw `TypeError: e.createTexture is not a function`. Pretending
        // WebGL works until the first non-stubbed call is the worst of both
        // worlds: pages that have an error boundary above the WebGL widget
        // catch the throw, reset, re-render, and loop forever.
        // Spec-correct signal for "no WebGL" is null, so apps that check
        // (Three.js does) can degrade gracefully.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            return null;
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// Largest canvas a real browser backs with a bitmap (16384 x 16384). Past
/// that, and at zero size, there are no pixels to serialize.
const max_area = 16384 * 16384;

const png_mime = "image/png";

/// A 1x1 fully transparent PNG.
///
/// We have no rasterizer - every `CanvasRenderingContext2D` draw call is a
/// no-op - so a canvas is always blank and every canvas serializes to this
/// same image. A real browser's output would carry the canvas' dimensions,
/// but nothing here can observe them (`Image.naturalWidth` is always 0), and
/// a constant keeps serialization O(1) no matter how large the canvas or how
/// often a page (typically a fingerprinting script) asks for it.
const blank_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==";
const blank_png_data_url = "data:" ++ png_mime ++ ";base64," ++ blank_png_base64;
const blank_png = blk: {
    const decoder = std.base64.standard.Decoder;
    var buf: [decoder.calcSizeForSlice(blank_png_base64) catch unreachable]u8 = undefined;
    decoder.decode(&buf, blank_png_base64) catch unreachable;
    const decoded = buf;
    break :blk decoded;
};

/// Whether the canvas has pixels to serialize at all. Both serializers answer
/// with the spec's "no data" values when it doesn't.
fn hasBitmap(self: *const Canvas) bool {
    const width = self.getWidth();
    const height = self.getHeight();
    return width > 0 and height > 0 and @as(u64, width) * height <= max_area;
}

/// Serializes the canvas, always as `blank_png`. Per spec an unsupported
/// `type` falls back to image/png, and with nothing drawn there is no lossy
/// encoding for `quality` to control, so both arguments are ignored.
pub fn toDataURL(self: *const Canvas, _: ?[]const u8, _: ?f64) []const u8 {
    // Per spec, a canvas with no pixels serializes to this exact string.
    return if (self.hasBitmap()) blank_png_data_url else "data:,";
}

/// Same image as `toDataURL`, handed to `callback` as a Blob from a task.
/// A canvas with no pixels calls back with null, per spec.
pub fn toBlob(self: *const Canvas, callback: js.Function.Global, _: ?[]const u8, _: ?f64, exec: *Execution) !void {
    const blob: ?*Blob = if (self.hasBitmap()) try Blob.initFromBytes(&blank_png, png_mime, exec) else null;
    errdefer if (blob) |b| b.releaseRef(exec.page);

    // The Blob outlives this call, so it needs a reference of its own until
    // the task has handed it to the callback.
    if (blob) |b| {
        b.acquireRef();
    }

    const task = try exec._factory.create(ToBlobCallback{
        .exec = exec,
        .blob = blob,
        .callback = callback,
    });
    errdefer exec._factory.destroy(task);

    try exec._scheduler.add(task, ToBlobCallback.run, 0, .{
        .name = "canvas.toBlob",
        .finalizer = ToBlobCallback.cancelled,
    });
}

const ToBlobCallback = struct {
    exec: *Execution,
    blob: ?*Blob,
    callback: js.Function.Global,

    // `run` and `cancelled` are mutually exclusive, so each releases exactly
    // once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *ToBlobCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn deinit(self: *ToBlobCallback) void {
        self.callback.release();
        if (self.blob) |b| {
            b.releaseRef(self.exec.page);
        }
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ToBlobCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        ls.toLocal(self.callback).call(void, .{self.blob}) catch |err| {
            self.exec.page.recordJsError(err);
            log.warn(.js, "canvas.toBlob", .{ .err = err });
        };
        return null;
    }
};

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Canvas);

    pub const width = reflect.unsignedLong("width", .{ .default = 300 });
    pub const height = reflect.unsignedLong("height", .{ .default = 150 });
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const toBlob = bridge.function(Canvas.toBlob, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLCanvasElement serialization" {
    try testing.htmlRunner("canvas/canvas_serialization.html", .{});
}

//! Canvas API.
//! https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API

const CanvasRenderingContext2D = @import("CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("WebGLRenderingContext.zig");
const Extension = WebGLRenderingContext.Extension;

pub const Interfaces = .{
    CanvasRenderingContext2D,
    WebGLRenderingContext,
    Extension.Type.WEBGL_debug_renderer_info,
};

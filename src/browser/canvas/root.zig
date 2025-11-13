//! Canvas API.
//! https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API

const WebGLRenderingContext = @import("WebGLRenderingContext.zig");
const ExtensionType = WebGLRenderingContext.Extension.Type;

pub const Interfaces = .{
    @import("CanvasRenderingContext2D.zig"),
    WebGLRenderingContext,
    ExtensionType.WEBGL_debug_renderer_info,
};

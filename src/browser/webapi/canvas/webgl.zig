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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! The no-op WebGL behind `--experimental-features webgl`. Every call
//! succeeds and draws nothing: shaders compile, programs link, framebuffers
//! are complete. Renderers that have no fallback for a null context (Skia,
//! for Compose and Flutter) then run, and their accessibility trees carry
//! the page's content. The methods that return nothing are generated into
//! WebGLRenderingContext.zig and WebGL2RenderingContext.zig as noops; the
//! ones that return a value are here.

const std = @import("std");
const lp = @import("lightpanda");

const Canvas = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");

const js = lp.js;

pub const WebGLBuffer = Object("WebGLBuffer");
pub const WebGLFramebuffer = Object("WebGLFramebuffer");
pub const WebGLProgram = Object("WebGLProgram");
pub const WebGLRenderbuffer = Object("WebGLRenderbuffer");
pub const WebGLShader = Object("WebGLShader");
pub const WebGLTexture = Object("WebGLTexture");
pub const WebGLUniformLocation = Object("WebGLUniformLocation");
pub const WebGLQuery = Object("WebGLQuery");
pub const WebGLSampler = Object("WebGLSampler");
pub const WebGLSync = Object("WebGLSync");
pub const WebGLTransformFeedback = Object("WebGLTransformFeedback");
pub const WebGLVertexArrayObject = Object("WebGLVertexArrayObject");

pub const object_types = [_]type{
    WebGLBuffer,  WebGLFramebuffer, WebGLProgram,           WebGLRenderbuffer,
    WebGLShader,  WebGLTexture,     WebGLUniformLocation,   WebGLQuery,
    WebGLSampler, WebGLSync,        WebGLTransformFeedback, WebGLVertexArrayObject,
};

/// Globals the flag adds: Env.hideWebGL deletes them when it's off.
pub const global_names = blk: {
    var names: [object_types.len + 1][:0]const u8 = undefined;
    names[0] = "WebGL2RenderingContext";
    for (object_types, names[1..]) |T, *name| {
        name.* = T.JsApi.Meta.name;
    }
    break :blk names;
};

fn Object(comptime class_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        _pad: u8 = 0,

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = class_name;

                pub var class_id: bridge.ClassId = undefined;
            };
        };
    };
}

pub const Version = enum { webgl1, webgl2 };

/// The canvas a context draws to, the `canvas` attribute
pub const Owner = union(enum) {
    canvas: *Canvas,
    offscreen: *OffscreenCanvas,

    fn width(self: Owner) u32 {
        return switch (self) {
            inline else => |c| c.getWidth(),
        };
    }

    fn height(self: Owner) u32 {
        return switch (self) {
            inline else => |c| c.getHeight(),
        };
    }
};

pub const Value = union(enum) {
    null: ?bool,
    bool: bool,
    int: i64,
    string: []const u8,
    int32: js.TypedArray(i32),
    uint32: js.TypedArray(u32),
    float32: js.TypedArray(f32),
    bools: []const bool,
};

const ContextAttributes = struct {
    alpha: bool = true,
    depth: bool = true,
    stencil: bool = false,
    antialias: bool = true,
    premultipliedAlpha: bool = true,
    preserveDrawingBuffer: bool = false,
    powerPreference: []const u8 = "default",
    failIfMajorPerformanceCaveat: bool = false,
    desynchronized: bool = false,
};

const ShaderPrecisionFormat = struct {
    rangeMin: i32 = 127,
    rangeMax: i32 = 127,
    precision: i32 = 23,
};

// What a desktop GPU reports, so renderers size their atlases as usual
fn limit(pname: u32) ?i64 {
    return switch (pname) {
        0x0D33 => 16384, // MAX_TEXTURE_SIZE
        0x84E8 => 16384, // MAX_RENDERBUFFER_SIZE
        0x851C => 16384, // MAX_CUBE_MAP_TEXTURE_SIZE
        0x8073 => 2048, // MAX_3D_TEXTURE_SIZE
        0x88FF => 2048, // MAX_ARRAY_TEXTURE_LAYERS
        0x8869 => 16, // MAX_VERTEX_ATTRIBS
        0x8872 => 16, // MAX_TEXTURE_IMAGE_UNITS
        0x8B4C => 16, // MAX_VERTEX_TEXTURE_IMAGE_UNITS
        0x8B4D => 32, // MAX_COMBINED_TEXTURE_IMAGE_UNITS
        0x8DFB => 4096, // MAX_VERTEX_UNIFORM_VECTORS
        0x8DFD => 1024, // MAX_FRAGMENT_UNIFORM_VECTORS
        0x8DFC => 30, // MAX_VARYING_VECTORS
        0x8B4A => 16384, // MAX_VERTEX_UNIFORM_COMPONENTS
        0x8B49 => 4096, // MAX_FRAGMENT_UNIFORM_COMPONENTS
        0x8B4B => 120, // MAX_VARYING_COMPONENTS
        0x9122 => 64, // MAX_VERTEX_OUTPUT_COMPONENTS
        0x9125 => 128, // MAX_FRAGMENT_INPUT_COMPONENTS
        0x8D57 => 4, // MAX_SAMPLES
        0x8824 => 8, // MAX_DRAW_BUFFERS
        0x8CDF => 8, // MAX_COLOR_ATTACHMENTS
        0x8A2B => 16, // MAX_VERTEX_UNIFORM_BLOCKS
        0x8A2D => 16, // MAX_FRAGMENT_UNIFORM_BLOCKS
        0x8A2E => 32, // MAX_COMBINED_UNIFORM_BLOCKS
        0x8A2F => 32, // MAX_UNIFORM_BUFFER_BINDINGS
        0x8A30 => 65536, // MAX_UNIFORM_BLOCK_SIZE
        0x8A31 => 65536, // MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS
        0x8A33 => 65536, // MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS
        0x8A34 => 256, // UNIFORM_BUFFER_OFFSET_ALIGNMENT
        0x8C8A => 128, // MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS
        0x8C8B => 4, // MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS
        0x8C80 => 4, // MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS
        0x8D6B => 4294967295, // MAX_ELEMENT_INDEX
        0x80E8 => 2147483647, // MAX_ELEMENTS_INDICES
        0x80E9 => 2147483647, // MAX_ELEMENTS_VERTICES
        0x84FD => 16, // MAX_TEXTURE_LOD_BIAS
        0x8904 => -8, // MIN_PROGRAM_TEXEL_OFFSET
        0x8905 => 7, // MAX_PROGRAM_TEXEL_OFFSET
        0x0D52 => 8, // RED_BITS
        0x0D53 => 8, // GREEN_BITS
        0x0D54 => 8, // BLUE_BITS
        0x0D55 => 8, // ALPHA_BITS
        0x0D56 => 24, // DEPTH_BITS
        0x0D57 => 8, // STENCIL_BITS
        0x0D50 => 4, // SUBPIXEL_BITS
        0x0CF5 => 4, // UNPACK_ALIGNMENT
        0x0D05 => 4, // PACK_ALIGNMENT
        0x8B9A => 0x1401, // IMPLEMENTATION_COLOR_READ_TYPE: UNSIGNED_BYTE
        0x8B9B => 0x1908, // IMPLEMENTATION_COLOR_READ_FORMAT: RGBA
        else => null,
    };
}

// Bindings start out empty
fn isBinding(pname: u32) bool {
    return switch (pname) {
        0x8894, 0x8895, 0x8CA6, 0x8CA7, 0x8069, 0x8514, 0x8B8D, 0x85B5, 0x8CAA, 0x8919, 0x88ED, 0x88EF, 0x8E25, 0x8F36, 0x8F37, 0x8C8F, 0x8A28, 0x806A, 0x8C1D => true,
        else => false,
    };
}

pub fn Methods(comptime Self: type, comptime version: Version) type {
    return struct {
        const vendor = "Lightpanda";
        const renderer = "Lightpanda (no-op WebGL)";
        const gl_version = switch (version) {
            .webgl1 => "WebGL 1.0 (Lightpanda no-op)",
            .webgl2 => "WebGL 2.0 (Lightpanda no-op)",
        };
        const glsl_version = switch (version) {
            .webgl1 => "WebGL GLSL ES 1.0 (Lightpanda no-op)",
            .webgl2 => "WebGL GLSL ES 3.00 (Lightpanda no-op)",
        };

        pub fn noop(_: *const Self) void {}

        pub fn getCanvas(self: *const Self) Owner {
            return self._canvas;
        }

        pub fn getDrawingBufferWidth(self: *const Self) u32 {
            return self._canvas.width();
        }

        pub fn getDrawingBufferHeight(self: *const Self) u32 {
            return self._canvas.height();
        }

        pub fn getDrawingBufferFormat(_: *const Self) u32 {
            return 0x8058; // RGBA8
        }

        pub fn getColorSpace(_: *const Self) []const u8 {
            return "srgb";
        }

        pub fn setColorSpace(_: *Self, _: []const u8) void {}

        pub fn getContextAttributes(_: *const Self) ContextAttributes {
            return .{};
        }

        pub fn getParameter(self: *const Self, pname: u32, exec: *const js.Execution) !Value {
            switch (pname) {
                0x1F00, 0x9245 => return .{ .string = vendor }, // VENDOR, UNMASKED_VENDOR_WEBGL
                0x1F01, 0x9246 => return .{ .string = renderer }, // RENDERER, UNMASKED_RENDERER_WEBGL
                0x1F02 => return .{ .string = gl_version },
                0x8B8C => return .{ .string = glsl_version },
                0x0D3A => return .{ .int32 = .{ .values = &.{ 16384, 16384 } } }, // MAX_VIEWPORT_DIMS
                0x0BA2, 0x0C10 => { // VIEWPORT, SCISSOR_BOX
                    const box = try exec.local_arena.dupe(i32, &.{ 0, 0, @intCast(self._canvas.width()), @intCast(self._canvas.height()) });
                    return .{ .int32 = .{ .values = box } };
                },
                0x846D, 0x846E => return .{ .float32 = .{ .values = &.{ 1, 1 } } }, // ALIASED_POINT_SIZE_RANGE, ALIASED_LINE_WIDTH_RANGE
                0x0B70 => return .{ .float32 = .{ .values = &.{ 0, 1 } } }, // DEPTH_RANGE
                0x0C22, 0x8005 => return .{ .float32 = .{ .values = &.{ 0, 0, 0, 0 } } }, // COLOR_CLEAR_VALUE, BLEND_COLOR
                0x0C23 => return .{ .bools = &.{ true, true, true, true } }, // COLOR_WRITEMASK
                0x86A3 => return .{ .uint32 = .{ .values = &.{} } }, // COMPRESSED_TEXTURE_FORMATS
                else => {},
            }
            if (limit(pname)) |value| {
                return .{ .int = value };
            }
            if (isBinding(pname)) {
                return .{ .null = null };
            }
            return .{ .int = 0 };
        }

        pub fn checkFramebufferStatus(_: *const Self) u32 {
            return 0x8CD5; // FRAMEBUFFER_COMPLETE
        }

        pub fn isObject(_: *const Self, object: ?js.Value) bool {
            const value = object orelse return false;
            return value.isObject();
        }

        pub fn zero(_: *const Self) i32 {
            return 0;
        }

        pub fn emptyString(_: *const Self) []const u8 {
            return "";
        }

        pub fn emptyList(_: *const Self) []const u32 {
            return &.{};
        }

        pub fn none(_: *const Self) ?bool {
            return null;
        }

        pub fn no(_: *const Self) bool {
            return false;
        }

        pub fn getShaderParameter(_: *const Self, _: js.Value, pname: u32) Value {
            return switch (pname) {
                0x8B81 => .{ .bool = true }, // COMPILE_STATUS
                0x8B80 => .{ .bool = false }, // DELETE_STATUS
                else => .{ .int = 0 },
            };
        }

        pub fn getProgramParameter(_: *const Self, _: js.Value, pname: u32) Value {
            return switch (pname) {
                0x8B82, 0x8B83 => .{ .bool = true }, // LINK_STATUS, VALIDATE_STATUS
                0x8B80 => .{ .bool = false }, // DELETE_STATUS
                else => .{ .int = 0 },
            };
        }

        pub fn getShaderPrecisionFormat(_: *const Self) ShaderPrecisionFormat {
            return .{};
        }

        pub fn getVertexAttrib(_: *const Self, _: u32, pname: u32) Value {
            return switch (pname) {
                0x8626 => .{ .float32 = .{ .values = &.{ 0, 0, 0, 1 } } }, // CURRENT_VERTEX_ATTRIB
                else => .{ .int = 0 },
            };
        }

        pub fn getInternalformatParameter(_: *const Self, _: u32, _: u32, pname: u32) Value {
            return switch (pname) {
                0x80A9 => .{ .int32 = .{ .values = &.{4} } }, // SAMPLES
                else => .{ .null = null },
            };
        }

        pub fn getQueryParameter(_: *const Self, _: js.Value, pname: u32) Value {
            return switch (pname) {
                0x8867 => .{ .bool = true }, // QUERY_RESULT_AVAILABLE
                else => .{ .int = 0 },
            };
        }

        pub fn getSyncParameter(_: *const Self, _: js.Value, pname: u32) Value {
            return switch (pname) {
                0x9114 => .{ .int = 0x9119 }, // SYNC_STATUS: SIGNALED
                0x9112 => .{ .int = 0x9116 }, // OBJECT_TYPE: SYNC_FENCE
                0x9113 => .{ .int = 0x9117 }, // SYNC_CONDITION: SYNC_GPU_COMMANDS_COMPLETE
                else => .{ .int = 0 },
            };
        }

        pub fn clientWaitSync(_: *const Self) u32 {
            return 0x911A; // ALREADY_SIGNALED
        }

        pub fn create(comptime T: type) fn (*const Self, *const js.Execution) anyerror!*T {
            return struct {
                fn create(_: *const Self, exec: *const js.Execution) !*T {
                    return exec._factory.create(T{});
                }
            }.create;
        }
    };
}

const testing = @import("../../../testing.zig");
test "WebApi: WebGL" {
    try testing.htmlRunner("canvas/webgl.html", .{ .experimental_features = .{ .webgl = true } });
}

test "WebApi: WebGL disabled" {
    try testing.htmlRunner("canvas/webgl_disabled.html", .{});
}

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
//! for Compose for Web) then run, and their accessibility trees carry the
//! page's content. WebGLRenderingContext.zig and WebGL2RenderingContext.zig
//! list every IDL member, with the methods that return nothing as noops; the
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

fn Object(comptime class_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = class_name;

                pub var class_id: bridge.ClassId = undefined;
                pub const optional_identity = true;
                pub const empty_with_no_proto = true;
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
        else => null,
    };
}

// A fresh context's state, as Chrome reports it. The values a page can change
// aren't tracked, except the capabilities (see Cap): they read back as set.
fn initial(pname: u32) ?Value {
    return switch (pname) {
        0x0D52, 0x0D53, 0x0D54, 0x0D55 => .{ .int = 8 }, // RED_BITS, GREEN_BITS, BLUE_BITS, ALPHA_BITS
        0x0D56 => .{ .int = 24 }, // DEPTH_BITS
        0x0D57 => .{ .int = 0 }, // STENCIL_BITS: the stencil attribute is false
        0x0D50 => .{ .int = 4 }, // SUBPIXEL_BITS
        0x80A9 => .{ .int = 4 }, // SAMPLES
        0x80A8 => .{ .int = 1 }, // SAMPLE_BUFFERS
        0x0CF5, 0x0D05 => .{ .int = 4 }, // UNPACK_ALIGNMENT, PACK_ALIGNMENT
        0x8B9A => .{ .int = 0x1401 }, // IMPLEMENTATION_COLOR_READ_TYPE: UNSIGNED_BYTE
        0x8B9B => .{ .int = 0x1908 }, // IMPLEMENTATION_COLOR_READ_FORMAT: RGBA
        0x8A34 => .{ .int = 256 }, // UNIFORM_BUFFER_OFFSET_ALIGNMENT
        0x84E0 => .{ .int = 0x84C0 }, // ACTIVE_TEXTURE: TEXTURE0
        0x8009, 0x883D => .{ .int = 0x8006 }, // BLEND_EQUATION_RGB, BLEND_EQUATION_ALPHA: FUNC_ADD
        0x80C9, 0x80CB => .{ .int = 1 }, // BLEND_SRC_RGB, BLEND_SRC_ALPHA: ONE
        0x0B45 => .{ .int = 0x0405 }, // CULL_FACE_MODE: BACK
        0x0B46 => .{ .int = 0x0901 }, // FRONT_FACE: CCW
        0x0B74 => .{ .int = 0x0201 }, // DEPTH_FUNC: LESS
        0x0B73, 0x0B21, 0x80AA => .{ .int = 1 }, // DEPTH_CLEAR_VALUE, LINE_WIDTH, SAMPLE_COVERAGE_VALUE
        0x0B72 => .{ .bool = true }, // DEPTH_WRITEMASK
        0x80AB, 0x9240, 0x9241, 0x8E24, 0x8E23 => .{ .bool = false }, // SAMPLE_COVERAGE_INVERT, UNPACK_FLIP_Y_WEBGL, UNPACK_PREMULTIPLY_ALPHA_WEBGL, TRANSFORM_FEEDBACK_ACTIVE, TRANSFORM_FEEDBACK_PAUSED
        0x8192, 0x8B8B => .{ .int = 0x1100 }, // GENERATE_MIPMAP_HINT, FRAGMENT_SHADER_DERIVATIVE_HINT: DONT_CARE
        0x0B92, 0x8800 => .{ .int = 0x0207 }, // STENCIL_FUNC, STENCIL_BACK_FUNC: ALWAYS
        0x0B94, 0x0B95, 0x0B96, 0x8801, 0x8802, 0x8803 => .{ .int = 0x1E00 }, // STENCIL_[BACK_]FAIL, _PASS_DEPTH_FAIL, _PASS_DEPTH_PASS: KEEP
        0x0B93, 0x8CA4, 0x0B98, 0x8CA5 => .{ .int = 0xFFFFFFFF }, // STENCIL_[BACK_]VALUE_MASK, STENCIL_[BACK_]WRITEMASK
        0x9243 => .{ .int = 0x9244 }, // UNPACK_COLORSPACE_CONVERSION_WEBGL: BROWSER_DEFAULT_WEBGL
        0x0C02, 0x8825...0x882C => .{ .int = 0x0405 }, // READ_BUFFER, DRAW_BUFFER0-7: BACK
        // Bindings start out empty
        0x8894, 0x8895, 0x8CA6, 0x8CA7, 0x8069, 0x8514, 0x8B8D, 0x85B5, 0x8CAA, 0x8919, 0x88ED, 0x88EF, 0x8E25, 0x8F36, 0x8F37, 0x8C8F, 0x8A28, 0x806A, 0x8C1D => .{ .null = null },
        else => null,
    };
}

/// The capabilities enable and disable switch, which isEnabled and
/// getParameter read back
pub const Cap = enum(u32) {
    blend = 0x0BE2,
    cull_face = 0x0B44,
    depth_test = 0x0B71,
    dither = 0x0BD0,
    polygon_offset_fill = 0x8037,
    rasterizer_discard = 0x8C89,
    sample_alpha_to_coverage = 0x809E,
    sample_coverage = 0x80A0,
    scissor_test = 0x0C11,
    stencil_test = 0x0B90,
};

pub const Caps = std.EnumSet(Cap);

// Only dither starts on
pub const default_caps: Caps = .initOne(.dither);

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
            if (std.enums.fromInt(Cap, pname)) |cap| {
                return .{ .bool = self._enabled.contains(cap) };
            }
            if (limit(pname)) |value| {
                return .{ .int = value };
            }
            return initial(pname) orelse .{ .int = 0 };
        }

        pub fn enable(self: *Self, cap: u32) void {
            self._enabled.insert(std.enums.fromInt(Cap, cap) orelse return);
        }

        pub fn disable(self: *Self, cap: u32) void {
            self._enabled.remove(std.enums.fromInt(Cap, cap) orelse return);
        }

        pub fn isEnabled(self: *const Self, cap: u32) bool {
            return self._enabled.contains(std.enums.fromInt(Cap, cap) orelse return false);
        }

        pub fn checkFramebufferStatus(_: *const Self) u32 {
            return 0x8CD5; // FRAMEBUFFER_COMPLETE
        }

        /// isBuffer, isTexture, …: whether a `T` exists and isn't deleted. As
        /// in GL, most only exist once bound (see bind). Null is false; another
        /// type is a TypeError.
        pub fn isLive(comptime T: type) fn (*const Self, ?js.Value) anyerror!bool {
            return struct {
                fn isLive(_: *const Self, object: ?js.Value) !bool {
                    const value = try objectOf(T, object) orelse return false;
                    if (comptime existsOnceBound(T)) {
                        if (!value.hasPrivateFlag("webgl_bound")) {
                            return false;
                        }
                    }
                    return !value.hasPrivateFlag("webgl_deleted");
                }
            }.isLive;
        }

        /// bindBuffer, bindTexture, beginQuery, …: the `T` after `skip`
        /// leading arguments exists from now on. Null unbinds; another type
        /// is a TypeError.
        pub fn bind(comptime T: type, comptime skip: enum { none, one, two }) switch (skip) {
            .none => fn (*const Self, ?js.Value) anyerror!void,
            .one => fn (*const Self, u32, ?js.Value) anyerror!void,
            .two => fn (*const Self, u32, u32, ?js.Value) anyerror!void,
        } {
            const Bind = struct {
                fn mark(object: ?js.Value) !void {
                    const value = try objectOf(T, object) orelse return;
                    value.setPrivateFlag("webgl_bound");
                }
                fn none(_: *const Self, object: ?js.Value) !void {
                    return mark(object);
                }
                fn one(_: *const Self, _: u32, object: ?js.Value) !void {
                    return mark(object);
                }
                fn two(_: *const Self, _: u32, _: u32, object: ?js.Value) !void {
                    return mark(object);
                }
            };
            return @field(Bind, @tagName(skip));
        }

        fn existsOnceBound(comptime T: type) bool {
            return switch (T) {
                WebGLBuffer, WebGLFramebuffer, WebGLRenderbuffer, WebGLTexture, WebGLQuery, WebGLTransformFeedback, WebGLVertexArrayObject => true,
                else => false,
            };
        }

        /// deleteBuffer, deleteTexture, …: marks a `T` deleted. Null does
        /// nothing; another type is a TypeError.
        pub fn delete(comptime T: type) fn (*const Self, ?js.Value) anyerror!void {
            return struct {
                fn delete(_: *const Self, object: ?js.Value) !void {
                    const value = try objectOf(T, object) orelse return;
                    value.setPrivateFlag("webgl_deleted");
                }
            }.delete;
        }

        fn objectOf(comptime T: type, object: ?js.Value) !?js.Value {
            const value = object orelse return null;
            if (value.isNullOrUndefined()) {
                return null;
            }
            if (!value.instanceOf(T)) {
                return error.InvalidArgument;
            }
            return value;
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

        /// A deleted shader has no parameters: null
        pub fn getShaderParameter(_: *const Self, shader: js.Value, pname: u32) Value {
            if (shader.hasPrivateFlag("webgl_deleted")) {
                return .{ .null = null };
            }
            return switch (pname) {
                0x8B81 => .{ .bool = true }, // COMPILE_STATUS
                0x8B80 => .{ .bool = false }, // DELETE_STATUS
                else => .{ .int = 0 },
            };
        }

        /// A deleted program has no parameters: null
        pub fn getProgramParameter(_: *const Self, program: js.Value, pname: u32) Value {
            if (program.hasPrivateFlag("webgl_deleted")) {
                return .{ .null = null };
            }
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

        pub fn create(comptime T: type) fn (*const Self) js.NoIdentity(T) {
            return struct {
                fn create(_: *const Self) js.NoIdentity(T) {
                    return .fresh;
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

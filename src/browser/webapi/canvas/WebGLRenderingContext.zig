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

const std = @import("std");

const js = @import("../../js/js.zig");
const Canvas = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");

/// Whichever canvas created the context — `.canvas` must report it, and a
/// worker only ever has an OffscreenCanvas. Keeping both owners here is what
/// lets the two threads agree about the GPU: a worker that could not get a
/// WebGL context at all reported no GPU while the main thread reported a full
/// vendor and renderer, and no real browser contradicts itself that way.
pub const CanvasOwner = union(enum) {
    canvas: *Canvas,
    offscreen: *OffscreenCanvas,
};

pub fn registerTypes() []const type {
    return &.{
        WebGLRenderingContext,
        WebGL2RenderingContext,
        Extension.Type.WEBGL_debug_renderer_info,
        Extension.Type.WEBGL_lose_context,
    };
}

/// Chrome 131 always ships both contexts, and WebGL2RenderingContext is a
/// sibling interface rather than a subclass -- its prototype chain stops at
/// Object, exactly like WebGL1's. Same stub body, different version strings.
pub const WebGLRenderingContext = Context(.webgl1);
pub const WebGL2RenderingContext = Context(.webgl2);

const Version = enum {
    webgl1,
    webgl2,

    fn interfaceName(self: Version) [:0]const u8 {
        return switch (self) {
            .webgl1 => "WebGLRenderingContext",
            .webgl2 => "WebGL2RenderingContext",
        };
    }

    fn versionString(self: Version) []const u8 {
        return switch (self) {
            .webgl1 => "WebGL 1.0 (OpenGL ES 2.0 Chromium)",
            .webgl2 => "WebGL 2.0 (OpenGL ES 3.0 Chromium)",
        };
    }

    fn shadingLanguageVersion(self: Version) []const u8 {
        return switch (self) {
            .webgl1 => "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)",
            .webgl2 => "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Chromium)",
        };
    }
};

const VENDOR = "WebKit";
const RENDERER = "WebKit WebGL";

// GLenum constants used by fingerprint scripts
const GL_VENDOR: u32 = 0x1F00;
const GL_RENDERER: u32 = 0x1F01;
const GL_VERSION: u32 = 0x1F02;
const GL_SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;
const GL_UNMASKED_VENDOR: u32 = 0x9245;
const GL_UNMASKED_RENDERER: u32 = 0x9246;
const GL_MAX_TEXTURE_SIZE: u32 = 0x0D33;
const GL_MAX_CUBE_MAP_TEXTURE_SIZE: u32 = 0x851C;
const GL_MAX_RENDERBUFFER_SIZE: u32 = 0x84E8;
const GL_MAX_VERTEX_ATTRIBS: u32 = 0x8869;
const GL_MAX_VERTEX_UNIFORM_VECTORS: u32 = 0x8DFB;
const GL_MAX_VARYING_VECTORS: u32 = 0x8DFC;
const GL_MAX_FRAGMENT_UNIFORM_VECTORS: u32 = 0x8DFD;
const GL_MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
const GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
const GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: u32 = 0x8B4C;
const GL_ALIASED_LINE_WIDTH_RANGE: u32 = 0x846E;
const GL_ALIASED_POINT_SIZE_RANGE: u32 = 0x846D;
const GL_MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
const GL_RED_BITS: u32 = 0x0D52;
const GL_GREEN_BITS: u32 = 0x0D53;
const GL_BLUE_BITS: u32 = 0x0D54;
const GL_ALPHA_BITS: u32 = 0x0D55;
const GL_DEPTH_BITS: u32 = 0x0D56;
const GL_STENCIL_BITS: u32 = 0x0D57;
const GL_MAX_ANISOTROPY_EXT: u32 = 0x84FF;

/// On Chrome and Safari, a call to `getSupportedExtensions` returns total of 39.
pub const Extension = union(enum) {
    ANGLE_instanced_arrays: void,
    EXT_blend_minmax: void,
    EXT_clip_control: void,
    EXT_color_buffer_half_float: void,
    EXT_depth_clamp: void,
    EXT_disjoint_timer_query: void,
    EXT_float_blend: void,
    EXT_frag_depth: void,
    EXT_polygon_offset_clamp: void,
    EXT_shader_texture_lod: void,
    EXT_texture_compression_bptc: void,
    EXT_texture_compression_rgtc: void,
    EXT_texture_filter_anisotropic: void,
    EXT_texture_mirror_clamp_to_edge: void,
    EXT_sRGB: void,
    KHR_parallel_shader_compile: void,
    OES_element_index_uint: void,
    OES_fbo_render_mipmap: void,
    OES_standard_derivatives: void,
    OES_texture_float: void,
    OES_texture_float_linear: void,
    OES_texture_half_float: void,
    OES_texture_half_float_linear: void,
    OES_vertex_array_object: void,
    WEBGL_blend_func_extended: void,
    WEBGL_color_buffer_float: void,
    WEBGL_compressed_texture_astc: void,
    WEBGL_compressed_texture_etc: void,
    WEBGL_compressed_texture_etc1: void,
    WEBGL_compressed_texture_pvrtc: void,
    WEBGL_compressed_texture_s3tc: void,
    WEBGL_compressed_texture_s3tc_srgb: void,
    WEBGL_debug_renderer_info: *Type.WEBGL_debug_renderer_info,
    WEBGL_debug_shaders: void,
    WEBGL_depth_texture: void,
    WEBGL_draw_buffers: void,
    WEBGL_lose_context: *Type.WEBGL_lose_context,
    WEBGL_multi_draw: void,
    WEBGL_polygon_mode: void,

    const Kind = blk: {
        const info = @typeInfo(Extension).@"union";
        const fields = info.fields;
        const Tag = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1);
        var names: [fields.len][:0]const u8 = undefined;
        for (fields, 0..) |field, i| {
            names[i] = field.name;
        }
        break :blk @Enum(Tag, .exhaustive, &names, &std.simd.iota(Tag, fields.len));
    };

    fn find(name: []const u8) ?Kind {
        const kvs = comptime build_kvs: {
            const T = Extension.Kind;
            const EnumKV = struct { []const u8, T };
            var kvs_array: [@typeInfo(T).@"enum".fields.len]EnumKV = undefined;
            for (@typeInfo(T).@"enum".fields, 0..) |enumField, i| {
                kvs_array[i] = .{ enumField.name, @field(T, enumField.name) };
            }
            break :build_kvs kvs_array[0..];
        };
        const Map = std.StaticStringMapWithEql(Extension.Kind, std.static_string_map.eqlAsciiIgnoreCase);
        const map = Map.initComptime(kvs);
        return map.get(name);
    }

    pub const Type = struct {
        pub const WEBGL_debug_renderer_info = struct {
            _: u8 = 0,
            pub const UNMASKED_VENDOR_WEBGL: u64 = 0x9245;
            pub const UNMASKED_RENDERER_WEBGL: u64 = 0x9246;

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_debug_renderer_info);

                pub const Meta = struct {
                    pub const name = "WEBGL_debug_renderer_info";
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const UNMASKED_VENDOR_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_VENDOR_WEBGL, .{ .template = false, .readonly = true });
                pub const UNMASKED_RENDERER_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL, .{ .template = false, .readonly = true });
            };
        };

        pub const WEBGL_lose_context = struct {
            _: u8 = 0,
            pub fn loseContext(_: *const WEBGL_lose_context) void {}
            pub fn restoreContext(_: *const WEBGL_lose_context) void {}

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_lose_context);

                pub const Meta = struct {
                    pub const name = "WEBGL_lose_context";
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const loseContext = bridge.function(WEBGL_lose_context.loseContext, .{ .noop = true });
                pub const restoreContext = bridge.function(WEBGL_lose_context.restoreContext, .{ .noop = true });
            };
        };
    };
};

fn Context(comptime version: Version) type {
    return struct {
        const Self = @This();

        /// Parent canvas (spec requires .canvas).
        _canvas: CanvasOwner,
        /// Seeded from the browser fingerprint profile when the context is
        /// created; drives readPixels / toDataURL so the GPU probe isn't an
        /// all-zero buffer.
        _fp_seed: u64 = 0xcbf29ce484222325,

        /// Distinct from the 2d context seed on the same canvas
        /// (0x57454247 = "WEBG"), and from the sibling WebGL version.
        pub fn fingerprintSeed(self: *const Self) u64 {
            return self._fp_seed ^ 0x57454247 ^ @intFromEnum(version);
        }

        /// Fingerprint probes draw a scene then hash readPixels — an all-zero
        /// buffer is a louder headless tell than a wrong GPU string. Fill it
        /// with the same seeded generator the 2d canvas and toDataURL use.
        /// ponytail: byte destinations only (UNSIGNED_BYTE, the format every
        /// probe uses); handle float/half-float views when something reads them.
        pub fn readPixels(self: *const Self, x: i32, y: i32, width: i32, height: i32, _: u32, _: u32, dest: ?js.Value) void {
            const value = dest orelse return;
            if (!value.isUint8Array() and !value.isUint8ClampedArray()) return;
            const pixels = value.local.jsValueToZig([]u8, value) catch return;

            var seed = self.fingerprintSeed();
            inline for (.{ x, y, width, height }) |v| {
                seed = (seed ^ @as(u64, @bitCast(@as(i64, v)))) *% 0x100000001b3;
            }
            Canvas.fillFingerprintPixels(pixels, seed, if (width > 0) @intCast(width) else 1);
        }

        pub fn getCanvas(self: *const Self) CanvasOwner {
            return self._canvas;
        }

        pub fn isContextLost(_: *const Self) bool {
            return false;
        }

        pub fn getContextAttributes(_: *const Self, exec: *const js.Execution) !js.Object {
            const obj = exec.js.local.?.newObject();
            _ = try obj.set("alpha", true, .{});
            _ = try obj.set("antialias", true, .{});
            _ = try obj.set("depth", true, .{});
            _ = try obj.set("desynchronized", false, .{});
            _ = try obj.set("failIfMajorPerformanceCaveat", false, .{});
            _ = try obj.set("powerPreference", "default", .{});
            _ = try obj.set("premultipliedAlpha", true, .{});
            _ = try obj.set("preserveDrawingBuffer", false, .{});
            _ = try obj.set("stencil", false, .{});
            _ = try obj.set("xrCompatible", false, .{});
            return obj;
        }

        /// Returns string or number depending on pname (fingerprint + basic GL limits).
        pub fn getParameter(_: *const Self, pname: u32, exec: *const js.Execution) !js.Value {
            const local = exec.js.local.?;
            const fp = exec.session.browser.app.config.fingerprint_profile;
            return switch (pname) {
                GL_VENDOR => local.newString(VENDOR).toValue(),
                GL_RENDERER => local.newString(RENDERER).toValue(),
                GL_VERSION => local.newString(version.versionString()).toValue(),
                GL_SHADING_LANGUAGE_VERSION => local.newString(version.shadingLanguageVersion()).toValue(),
                GL_UNMASKED_VENDOR => local.newString(fp.gpu_vendor).toValue(),
                GL_UNMASKED_RENDERER => local.newString(fp.gpu_renderer).toValue(),
                GL_MAX_TEXTURE_SIZE, GL_MAX_CUBE_MAP_TEXTURE_SIZE, GL_MAX_RENDERBUFFER_SIZE => try local.newNumber(@as(f64, 16384)),
                GL_MAX_VERTEX_ATTRIBS => try local.newNumber(@as(f64, 16)),
                GL_MAX_VERTEX_UNIFORM_VECTORS => try local.newNumber(@as(f64, 4096)),
                GL_MAX_VARYING_VECTORS => try local.newNumber(@as(f64, 30)),
                GL_MAX_FRAGMENT_UNIFORM_VECTORS => try local.newNumber(@as(f64, 1024)),
                GL_MAX_TEXTURE_IMAGE_UNITS, GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS => try local.newNumber(@as(f64, 16)),
                GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS => try local.newNumber(@as(f64, 16)),
                GL_RED_BITS, GL_GREEN_BITS, GL_BLUE_BITS, GL_ALPHA_BITS => try local.newNumber(@as(f64, 8)),
                GL_DEPTH_BITS => try local.newNumber(@as(f64, 24)),
                GL_STENCIL_BITS => try local.newNumber(@as(f64, 0)),
                GL_MAX_ANISOTROPY_EXT => try local.newNumber(@as(f64, 16)),
                GL_ALIASED_LINE_WIDTH_RANGE, GL_ALIASED_POINT_SIZE_RANGE => blk: {
                    var arr = local.newArray(2);
                    _ = try arr.set(0, @as(f64, 1), .{});
                    _ = try arr.set(1, @as(f64, 1), .{});
                    break :blk arr.toValue();
                },
                GL_MAX_VIEWPORT_DIMS => blk: {
                    var arr = local.newArray(2);
                    _ = try arr.set(0, @as(f64, 16384), .{});
                    _ = try arr.set(1, @as(f64, 16384), .{});
                    break :blk arr.toValue();
                },
                else => local.newString("").toValue(),
            };
        }

        // Takes the Execution rather than the Frame: a worker has no Frame, so
        // asking for one panicked the moment an OffscreenCanvas context called
        // getExtension. Only `_factory` was ever needed, and Execution carries
        // it under the same name.
        pub fn getExtension(_: *const Self, name: []const u8, exec: *const js.Execution) !?Extension {
            const tag = Extension.find(name) orelse return null;

            return switch (tag) {
                .WEBGL_debug_renderer_info => {
                    const info = try exec._factory.create(Extension.Type.WEBGL_debug_renderer_info{});
                    return .{ .WEBGL_debug_renderer_info = info };
                },
                .WEBGL_lose_context => {
                    const ctx = try exec._factory.create(Extension.Type.WEBGL_lose_context{});
                    return .{ .WEBGL_lose_context = ctx };
                },
                inline else => |comptime_enum| @unionInit(Extension, @tagName(comptime_enum), {}),
            };
        }

        pub fn getSupportedExtensions(_: *const Self) []const []const u8 {
            return std.meta.fieldNames(Extension.Kind);
        }

        pub fn getShaderPrecisionFormat(_: *const Self, _: u32, _: u32, exec: *const js.Execution) !js.Object {
            const obj = exec.js.local.?.newObject();
            _ = try obj.set("rangeMin", @as(i32, 127), .{});
            _ = try obj.set("rangeMax", @as(i32, 127), .{});
            _ = try obj.set("precision", @as(i32, 23), .{});
            return obj;
        }

        // Resource / draw no-ops — prevent TypeError cascades on partial WebGL consumers.
        pub fn createBuffer(_: *const Self) void {}
        pub fn createTexture(_: *const Self) void {}
        pub fn createProgram(_: *const Self) void {}
        pub fn createShader(_: *const Self, _: u32) void {}
        pub fn createFramebuffer(_: *const Self) void {}
        pub fn createRenderbuffer(_: *const Self) void {}
        pub fn deleteBuffer(_: *const Self, _: ?js.Value) void {}
        pub fn deleteTexture(_: *const Self, _: ?js.Value) void {}
        pub fn deleteProgram(_: *const Self, _: ?js.Value) void {}
        pub fn deleteShader(_: *const Self, _: ?js.Value) void {}
        pub fn bindBuffer(_: *const Self, _: u32, _: ?js.Value) void {}
        pub fn bindTexture(_: *const Self, _: u32, _: ?js.Value) void {}
        pub fn bindFramebuffer(_: *const Self, _: u32, _: ?js.Value) void {}
        pub fn bindRenderbuffer(_: *const Self, _: u32, _: ?js.Value) void {}
        pub fn shaderSource(_: *const Self, _: ?js.Value, _: []const u8) void {}
        pub fn compileShader(_: *const Self, _: ?js.Value) void {}
        pub fn attachShader(_: *const Self, _: ?js.Value, _: ?js.Value) void {}
        pub fn linkProgram(_: *const Self, _: ?js.Value) void {}
        pub fn useProgram(_: *const Self, _: ?js.Value) void {}
        pub fn viewport(_: *const Self, _: f64, _: f64, _: f64, _: f64) void {}
        pub fn clearColor(_: *const Self, _: f64, _: f64, _: f64, _: f64) void {}
        pub fn clear(_: *const Self, _: u32) void {}
        pub fn enable(_: *const Self, _: u32) void {}
        pub fn disable(_: *const Self, _: u32) void {}
        pub fn drawArrays(_: *const Self, _: u32, _: i32, _: i32) void {}
        pub fn drawElements(_: *const Self, _: u32, _: i32, _: u32, _: i32) void {}
        pub fn getAttribLocation(_: *const Self, _: ?js.Value, _: []const u8) i32 {
            return -1;
        }
        pub fn getUniformLocation(_: *const Self, _: ?js.Value, _: []const u8) void {}
        pub fn getError(_: *const Self) u32 {
            return 0; // NO_ERROR
        }
        pub fn getShaderParameter(_: *const Self, _: ?js.Value, _: u32) bool {
            return true;
        }
        pub fn getProgramParameter(_: *const Self, _: ?js.Value, _: u32) bool {
            return true;
        }
        pub fn getShaderInfoLog(_: *const Self, _: ?js.Value) []const u8 {
            return "";
        }
        pub fn getProgramInfoLog(_: *const Self, _: ?js.Value) []const u8 {
            return "";
        }
        pub fn pixelStorei(_: *const Self, _: u32, _: i32) void {}
        pub fn texImage2D(_: *const Self, _: u32, _: i32, _: i32, _: i32, _: i32, _: i32, _: u32, _: u32, _: ?js.Value) void {}
        pub fn texParameteri(_: *const Self, _: u32, _: u32, _: i32) void {}
        pub fn activeTexture(_: *const Self, _: u32) void {}
        pub fn bufferData(_: *const Self, _: u32, _: ?js.Value, _: u32) void {}
        pub fn enableVertexAttribArray(_: *const Self, _: u32) void {}
        pub fn vertexAttribPointer(_: *const Self, _: u32, _: i32, _: u32, _: bool, _: i32, _: i32) void {}
        pub fn uniform1f(_: *const Self, _: ?js.Value, _: f64) void {}
        pub fn uniform1i(_: *const Self, _: ?js.Value, _: i32) void {}
        pub fn uniform2f(_: *const Self, _: ?js.Value, _: f64, _: f64) void {}
        pub fn uniformMatrix4fv(_: *const Self, _: ?js.Value, _: bool, _: ?js.Value) void {}
        pub fn scissor(_: *const Self, _: i32, _: i32, _: i32, _: i32) void {}
        pub fn blendFunc(_: *const Self, _: u32, _: u32) void {}
        pub fn depthFunc(_: *const Self, _: u32) void {}
        pub fn cullFace(_: *const Self, _: u32) void {}
        pub fn frontFace(_: *const Self, _: u32) void {}

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = version.interfaceName();
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const canvas = bridge.accessor(Self.getCanvas, null, .{});
            pub const drawingBufferWidth = bridge.property(300, .{ .template = false, .readonly = true });
            pub const drawingBufferHeight = bridge.property(150, .{ .template = false, .readonly = true });

            // Common GLenum constants as instance properties (Chrome exposes these)
            pub const VENDOR = bridge.property(GL_VENDOR, .{ .template = false, .readonly = true });
            pub const RENDERER = bridge.property(GL_RENDERER, .{ .template = false, .readonly = true });
            pub const VERSION = bridge.property(GL_VERSION, .{ .template = false, .readonly = true });
            pub const SHADING_LANGUAGE_VERSION = bridge.property(GL_SHADING_LANGUAGE_VERSION, .{ .template = false, .readonly = true });
            pub const MAX_TEXTURE_SIZE = bridge.property(GL_MAX_TEXTURE_SIZE, .{ .template = false, .readonly = true });
            pub const NO_ERROR = bridge.property(@as(u32, 0), .{ .template = false, .readonly = true });
            pub const ARRAY_BUFFER = bridge.property(@as(u32, 0x8892), .{ .template = false, .readonly = true });
            pub const ELEMENT_ARRAY_BUFFER = bridge.property(@as(u32, 0x8893), .{ .template = false, .readonly = true });
            pub const TEXTURE_2D = bridge.property(@as(u32, 0x0DE1), .{ .template = false, .readonly = true });
            pub const FLOAT = bridge.property(@as(u32, 0x1406), .{ .template = false, .readonly = true });
            pub const UNSIGNED_BYTE = bridge.property(@as(u32, 0x1401), .{ .template = false, .readonly = true });
            pub const TRIANGLES = bridge.property(@as(u32, 0x0004), .{ .template = false, .readonly = true });
            pub const COLOR_BUFFER_BIT = bridge.property(@as(u32, 0x00004000), .{ .template = false, .readonly = true });
            pub const DEPTH_BUFFER_BIT = bridge.property(@as(u32, 0x00000100), .{ .template = false, .readonly = true });
            pub const FRAGMENT_SHADER = bridge.property(@as(u32, 0x8B30), .{ .template = false, .readonly = true });
            pub const VERTEX_SHADER = bridge.property(@as(u32, 0x8B31), .{ .template = false, .readonly = true });
            pub const COMPILE_STATUS = bridge.property(@as(u32, 0x8B81), .{ .template = false, .readonly = true });
            pub const LINK_STATUS = bridge.property(@as(u32, 0x8B82), .{ .template = false, .readonly = true });

            pub const getParameter = bridge.function(Self.getParameter, .{});
            pub const getExtension = bridge.function(Self.getExtension, .{});
            pub const getSupportedExtensions = bridge.function(Self.getSupportedExtensions, .{});
            pub const getContextAttributes = bridge.function(Self.getContextAttributes, .{});
            pub const getShaderPrecisionFormat = bridge.function(Self.getShaderPrecisionFormat, .{});
            pub const isContextLost = bridge.function(Self.isContextLost, .{});

            pub const createBuffer = bridge.function(Self.createBuffer, .{ .noop = true });
            pub const createTexture = bridge.function(Self.createTexture, .{ .noop = true });
            pub const createProgram = bridge.function(Self.createProgram, .{ .noop = true });
            pub const createShader = bridge.function(Self.createShader, .{ .noop = true });
            pub const createFramebuffer = bridge.function(Self.createFramebuffer, .{ .noop = true });
            pub const createRenderbuffer = bridge.function(Self.createRenderbuffer, .{ .noop = true });
            pub const deleteBuffer = bridge.function(Self.deleteBuffer, .{ .noop = true });
            pub const deleteTexture = bridge.function(Self.deleteTexture, .{ .noop = true });
            pub const deleteProgram = bridge.function(Self.deleteProgram, .{ .noop = true });
            pub const deleteShader = bridge.function(Self.deleteShader, .{ .noop = true });
            pub const bindBuffer = bridge.function(Self.bindBuffer, .{ .noop = true });
            pub const bindTexture = bridge.function(Self.bindTexture, .{ .noop = true });
            pub const bindFramebuffer = bridge.function(Self.bindFramebuffer, .{ .noop = true });
            pub const bindRenderbuffer = bridge.function(Self.bindRenderbuffer, .{ .noop = true });
            pub const shaderSource = bridge.function(Self.shaderSource, .{ .noop = true });
            pub const compileShader = bridge.function(Self.compileShader, .{ .noop = true });
            pub const attachShader = bridge.function(Self.attachShader, .{ .noop = true });
            pub const linkProgram = bridge.function(Self.linkProgram, .{ .noop = true });
            pub const useProgram = bridge.function(Self.useProgram, .{ .noop = true });
            pub const viewport = bridge.function(Self.viewport, .{ .noop = true });
            pub const clearColor = bridge.function(Self.clearColor, .{ .noop = true });
            pub const clear = bridge.function(Self.clear, .{ .noop = true });
            pub const enable = bridge.function(Self.enable, .{ .noop = true });
            pub const disable = bridge.function(Self.disable, .{ .noop = true });
            pub const drawArrays = bridge.function(Self.drawArrays, .{ .noop = true });
            pub const drawElements = bridge.function(Self.drawElements, .{ .noop = true });
            pub const getAttribLocation = bridge.function(Self.getAttribLocation, .{});
            pub const getUniformLocation = bridge.function(Self.getUniformLocation, .{ .noop = true });
            pub const getError = bridge.function(Self.getError, .{});
            pub const getShaderParameter = bridge.function(Self.getShaderParameter, .{});
            pub const getProgramParameter = bridge.function(Self.getProgramParameter, .{});
            pub const getShaderInfoLog = bridge.function(Self.getShaderInfoLog, .{});
            pub const getProgramInfoLog = bridge.function(Self.getProgramInfoLog, .{});
            pub const pixelStorei = bridge.function(Self.pixelStorei, .{ .noop = true });
            pub const texImage2D = bridge.function(Self.texImage2D, .{ .noop = true });
            pub const texParameteri = bridge.function(Self.texParameteri, .{ .noop = true });
            pub const activeTexture = bridge.function(Self.activeTexture, .{ .noop = true });
            pub const bufferData = bridge.function(Self.bufferData, .{ .noop = true });
            pub const enableVertexAttribArray = bridge.function(Self.enableVertexAttribArray, .{ .noop = true });
            pub const vertexAttribPointer = bridge.function(Self.vertexAttribPointer, .{ .noop = true });
            pub const uniform1f = bridge.function(Self.uniform1f, .{ .noop = true });
            pub const uniform1i = bridge.function(Self.uniform1i, .{ .noop = true });
            pub const uniform2f = bridge.function(Self.uniform2f, .{ .noop = true });
            pub const uniformMatrix4fv = bridge.function(Self.uniformMatrix4fv, .{ .noop = true });
            pub const scissor = bridge.function(Self.scissor, .{ .noop = true });
            pub const blendFunc = bridge.function(Self.blendFunc, .{ .noop = true });
            pub const depthFunc = bridge.function(Self.depthFunc, .{ .noop = true });
            pub const cullFace = bridge.function(Self.cullFace, .{ .noop = true });
            pub const frontFace = bridge.function(Self.frontFace, .{ .noop = true });
            pub const readPixels = bridge.function(Self.readPixels, .{});
        };
    };
}

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}

test "WebApi: WebGL agrees across threads" {
    try testing.htmlRunner("webgl_worker.html", .{});
}

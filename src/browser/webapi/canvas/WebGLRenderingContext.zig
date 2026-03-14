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

const std = @import("std");

const color = @import("../../color.zig");
const js = @import("../../js/js.zig");
const TaggedOpaque = @import("../../js/TaggedOpaque.zig");
const Page = @import("../../Page.zig");
const CanvasSurface = @import("CanvasSurface.zig");

pub fn registerTypes() []const type {
    return &.{
        WebGLRenderingContext,
        WebGLShader,
        WebGLProgram,
        WebGLBuffer,
        WebGLUniformLocation,
        // Extension types should be runtime generated. We might want
        // to revisit this.
        Extension.Type.WEBGL_debug_renderer_info,
        Extension.Type.WEBGL_lose_context,
    };
}

const WebGLRenderingContext = @This();

const Viewport = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const Vertex = struct {
    x: f32,
    y: f32,
};

const VertexAttribState = struct {
    enabled: bool = false,
    size: i32 = 0,
    kind: u32 = 0,
    normalized: bool = false,
    stride: i32 = 0,
    offset: i32 = 0,
    buffer: ?*WebGLBuffer = null,
};

_surface: *CanvasSurface,
_clear_color: [4]f64 = .{ 0, 0, 0, 0 },
_viewport_x: i32 = 0,
_viewport_y: i32 = 0,
_viewport_width: i32 = 0,
_viewport_height: i32 = 0,
_current_program: ?*WebGLProgram = null,
_bound_array_buffer: ?*WebGLBuffer = null,
_bound_element_array_buffer: ?*WebGLBuffer = null,
_attrib0: VertexAttribState = .{},

pub const WebGLShader = struct {
    _type: u32,
    _source: []const u8 = &.{},
    _compiled: bool = false,
    _attribute_name: []const u8 = &.{},
    _uniform_name: []const u8 = &.{},
    _fragment_color: color.RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 255 },

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLShader);

        pub const Meta = struct {
            pub const name = "WebGLShader";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const WebGLProgram = struct {
    _vertex_shader: ?*WebGLShader = null,
    _fragment_shader: ?*WebGLShader = null,
    _linked: bool = false,
    _position_attribute_name: []const u8 = "a_position",
    _fragment_uniform_name: []const u8 = &.{},
    _fragment_color: color.RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    _uniform_color: ?color.RGBA = null,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLProgram);

        pub const Meta = struct {
            pub const name = "WebGLProgram";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const WebGLBuffer = struct {
    _bytes: []const u8 = &.{},

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLBuffer);

        pub const Meta = struct {
            pub const name = "WebGLBuffer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const WebGLUniformLocation = struct {
    _program: *WebGLProgram,
    _name: []const u8,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLUniformLocation);

        pub const Meta = struct {
            pub const name = "WebGLUniformLocation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub fn getDrawingBufferWidth(self: *const WebGLRenderingContext) u32 {
    return self._surface.width;
}

pub fn getDrawingBufferHeight(self: *const WebGLRenderingContext) u32 {
    return self._surface.height;
}

/// On Chrome and Safari, a call to `getSupportedExtensions` returns total of 39.
/// The reference for it lists lesser number of extensions:
/// https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Using_Extensions#extension_list
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

    /// Reified enum type from the fields of this union.
    const Kind = blk: {
        const info = @typeInfo(Extension).@"union";
        const fields = info.fields;
        var items: [fields.len]std.builtin.Type.EnumField = undefined;
        for (fields, 0..) |field, i| {
            items[i] = .{ .name = field.name, .value = i };
        }

        break :blk @Type(.{
            .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1),
                .fields = &items,
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    };

    /// Returns the `Extension.Kind` by its name.
    fn find(name: []const u8) ?Kind {
        // Just to make you really sad, this function has to be case-insensitive.
        // So here we copy what's being done in `std.meta.stringToEnum` but replace
        // the comparison function.
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

    /// Extension types.
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

/// This actually takes "GLenum" which, in fact, is a fancy way to say number.
/// Return value also depends on what's being passed as `pname`; we don't really
/// support any though.
pub fn getParameter(_: *const WebGLRenderingContext, pname: u32) []const u8 {
    _ = pname;
    return "";
}

pub const COLOR_BUFFER_BIT: u32 = 0x00004000;
pub const FLOAT: u32 = 0x1406;
pub const UNSIGNED_SHORT: u32 = 0x1403;
pub const ARRAY_BUFFER: u32 = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: u32 = 0x8893;
pub const STATIC_DRAW: u32 = 0x88E4;
pub const TRIANGLES: u32 = 0x0004;
pub const VERTEX_SHADER: u32 = 0x8B31;
pub const FRAGMENT_SHADER: u32 = 0x8B30;
pub const COMPILE_STATUS: u32 = 0x8B81;
pub const LINK_STATUS: u32 = 0x8B82;

pub fn clearColor(self: *WebGLRenderingContext, red: f64, green: f64, blue: f64, alpha: f64) void {
    self._clear_color = .{
        std.math.clamp(red, 0, 1),
        std.math.clamp(green, 0, 1),
        std.math.clamp(blue, 0, 1),
        std.math.clamp(alpha, 0, 1),
    };
}

pub fn clear(self: *WebGLRenderingContext, mask: u32) void {
    if ((mask & COLOR_BUFFER_BIT) == 0) return;

    self._surface.fillRect(.{
        .r = @intFromFloat(@round(self._clear_color[0] * 255.0)),
        .g = @intFromFloat(@round(self._clear_color[1] * 255.0)),
        .b = @intFromFloat(@round(self._clear_color[2] * 255.0)),
        .a = @intFromFloat(@round(self._clear_color[3] * 255.0)),
    }, 0, 0, @floatFromInt(self._surface.width), @floatFromInt(self._surface.height));
}

pub fn createShader(_: *WebGLRenderingContext, shader_type: u32, page: *Page) !?*WebGLShader {
    if (!isShaderType(shader_type)) return null;
    return page._factory.create(WebGLShader{
        ._type = shader_type,
    });
}

pub fn shaderSource(_: *WebGLRenderingContext, shader: *WebGLShader, source: []const u8, page: *Page) !void {
    shader._source = try page.arena.dupe(u8, source);
}

pub fn compileShader(_: *WebGLRenderingContext, shader: *WebGLShader) void {
    shader._compiled = false;
    if (!isShaderType(shader._type)) return;
    if (shader._source.len == 0) return;
    if (std.mem.indexOf(u8, shader._source, "void main") == null) return;

    if (shader._type == VERTEX_SHADER) {
        shader._attribute_name = parseFirstAttributeName(shader._source) orelse "a_position";
    } else {
        shader._uniform_name = parseFirstUniformName(shader._source) orelse &.{};
        if (parseFirstVec4Color(shader._source)) |rgba| {
            shader._fragment_color = rgba;
        }
    }
    shader._compiled = true;
}

pub fn getShaderParameter(_: *WebGLRenderingContext, shader: *WebGLShader, pname: u32) bool {
    if (pname == COMPILE_STATUS) {
        return shader._compiled;
    }
    return false;
}

pub fn createProgram(_: *WebGLRenderingContext, page: *Page) !*WebGLProgram {
    return page._factory.create(WebGLProgram{});
}

pub fn attachShader(_: *WebGLRenderingContext, program: *WebGLProgram, shader: *WebGLShader) void {
    switch (shader._type) {
        VERTEX_SHADER => program._vertex_shader = shader,
        FRAGMENT_SHADER => program._fragment_shader = shader,
        else => {},
    }
}

pub fn linkProgram(self: *WebGLRenderingContext, program: *WebGLProgram) void {
    program._linked = false;
    const vertex_shader = program._vertex_shader orelse return;
    const fragment_shader = program._fragment_shader orelse return;
    if (!vertex_shader._compiled or !fragment_shader._compiled) return;

    program._position_attribute_name = if (vertex_shader._attribute_name.len > 0)
        vertex_shader._attribute_name
    else
        "a_position";
    program._fragment_uniform_name = fragment_shader._uniform_name;
    program._fragment_color = fragment_shader._fragment_color;
    program._uniform_color = null;
    program._linked = true;
    self._current_program = program;
}

pub fn getProgramParameter(_: *WebGLRenderingContext, program: *WebGLProgram, pname: u32) bool {
    if (pname == LINK_STATUS) {
        return program._linked;
    }
    return false;
}

pub fn useProgram(self: *WebGLRenderingContext, program: js.Object) void {
    const actual_program = TaggedOpaque.fromJS(*WebGLProgram, program.handle) catch return;
    self._current_program = if (actual_program._linked) actual_program else null;
}

pub fn createBuffer(_: *WebGLRenderingContext, page: *Page) !*WebGLBuffer {
    return page._factory.create(WebGLBuffer{});
}

pub fn bindBuffer(self: *WebGLRenderingContext, target: u32, buffer: ?*WebGLBuffer) void {
    switch (target) {
        ARRAY_BUFFER => self._bound_array_buffer = buffer,
        ELEMENT_ARRAY_BUFFER => self._bound_element_array_buffer = buffer,
        else => {},
    }
}

pub fn bufferData(self: *WebGLRenderingContext, target: u32, data: js.Value.Temp, usage: u32, page: *Page) !void {
    _ = usage;
    const bytes = try typedArrayBytes(data.local(page.js.local.?));
    const buffer = switch (target) {
        ARRAY_BUFFER => self._bound_array_buffer orelse return,
        ELEMENT_ARRAY_BUFFER => self._bound_element_array_buffer orelse return,
        else => return,
    };
    buffer._bytes = try page.arena.dupe(u8, bytes);
}

pub fn getAttribLocation(_: *WebGLRenderingContext, program: *WebGLProgram, name: []const u8) i32 {
    if (!program._linked) return -1;
    if (std.mem.eql(u8, name, program._position_attribute_name)) {
        return 0;
    }
    return -1;
}

pub fn getUniformLocation(_: *WebGLRenderingContext, program: *WebGLProgram, name: []const u8, page: *Page) !?*WebGLUniformLocation {
    if (!program._linked) return null;
    if (program._fragment_uniform_name.len == 0) return null;
    if (!std.mem.eql(u8, name, program._fragment_uniform_name)) return null;
    return try page._factory.create(WebGLUniformLocation{
        ._program = program,
        ._name = try page.arena.dupe(u8, name),
    });
}

pub fn uniform4f(self: *WebGLRenderingContext, location: js.Object, x: f32, y: f32, z: f32, w: f32) void {
    const program = blk: {
        const actual_location = TaggedOpaque.fromJS(*WebGLUniformLocation, location.handle) catch break :blk self._current_program orelse return;
        break :blk actual_location._program;
    };
    if (!program._linked) {
        return;
    }
    program._uniform_color = .{
        .r = @intFromFloat(@round(std.math.clamp(@as(f64, x), 0, 1) * 255.0)),
        .g = @intFromFloat(@round(std.math.clamp(@as(f64, y), 0, 1) * 255.0)),
        .b = @intFromFloat(@round(std.math.clamp(@as(f64, z), 0, 1) * 255.0)),
        .a = @intFromFloat(@round(std.math.clamp(@as(f64, w), 0, 1) * 255.0)),
    };
}

pub fn vertexAttribPointer(
    self: *WebGLRenderingContext,
    index: u32,
    size: i32,
    kind: u32,
    normalized: bool,
    stride: i32,
    offset: i32,
) void {
    if (index != 0) return;
    self._attrib0.size = size;
    self._attrib0.kind = kind;
    self._attrib0.normalized = normalized;
    self._attrib0.stride = stride;
    self._attrib0.offset = offset;
    self._attrib0.buffer = self._bound_array_buffer;
}

pub fn enableVertexAttribArray(self: *WebGLRenderingContext, index: u32) void {
    if (index != 0) return;
    self._attrib0.enabled = true;
}

pub fn viewport(self: *WebGLRenderingContext, x: i32, y: i32, width: i32, height: i32) void {
    self._viewport_x = x;
    self._viewport_y = y;
    self._viewport_width = @max(width, 0);
    self._viewport_height = @max(height, 0);
}

pub fn drawArrays(self: *WebGLRenderingContext, mode: u32, first: i32, count: i32) void {
    if (mode != TRIANGLES or first < 0 or count < 3) return;
    const program = self._current_program orelse return;
    if (!program._linked) return;
    if (!self._attrib0.enabled) return;
    if (self._attrib0.kind != FLOAT or self._attrib0.size < 2 or self._attrib0.offset < 0) return;

    const buffer = self._attrib0.buffer orelse return;
    if (buffer._bytes.len == 0) return;

    const stride_bytes = if (self._attrib0.stride > 0) self._attrib0.stride else self._attrib0.size * @as(i32, @sizeOf(f32));
    if (stride_bytes <= 0) return;

    const viewport_rect = self.currentViewport();
    const fill_color = programFillColor(program);
    var vertex_index: i32 = first;
    while (vertex_index + 2 < first + count) : (vertex_index += 3) {
        const a = readVertex(buffer._bytes, self._attrib0, stride_bytes, vertex_index) orelse break;
        const b = readVertex(buffer._bytes, self._attrib0, stride_bytes, vertex_index + 1) orelse break;
        const c = readVertex(buffer._bytes, self._attrib0, stride_bytes, vertex_index + 2) orelse break;

        const ax, const ay = clipToViewport(a, viewport_rect);
        const bx, const by = clipToViewport(b, viewport_rect);
        const cx, const cy = clipToViewport(c, viewport_rect);
        self._surface.fillTriangle(fill_color, ax, ay, bx, by, cx, cy);
    }
}

pub fn drawElements(self: *WebGLRenderingContext, mode: u32, count: i32, kind: u32, offset: i32) void {
    if (mode != TRIANGLES or count < 3 or offset < 0 or kind != UNSIGNED_SHORT) return;
    const program = self._current_program orelse return;
    if (!program._linked) return;
    if (!self._attrib0.enabled) return;
    if (self._attrib0.kind != FLOAT or self._attrib0.size < 2 or self._attrib0.offset < 0) return;

    const vertex_buffer = self._attrib0.buffer orelse return;
    if (vertex_buffer._bytes.len == 0) return;
    const element_buffer = self._bound_element_array_buffer orelse return;
    if (element_buffer._bytes.len == 0) return;

    const stride_bytes = if (self._attrib0.stride > 0) self._attrib0.stride else self._attrib0.size * @as(i32, @sizeOf(f32));
    if (stride_bytes <= 0) return;

    const viewport_rect = self.currentViewport();
    const fill_color = programFillColor(program);
    var element_index: i32 = 0;
    while (element_index + 2 < count) : (element_index += 3) {
        const ia = readElementIndex(element_buffer._bytes, offset, element_index) orelse break;
        const ib = readElementIndex(element_buffer._bytes, offset, element_index + 1) orelse break;
        const ic = readElementIndex(element_buffer._bytes, offset, element_index + 2) orelse break;

        const a = readVertex(vertex_buffer._bytes, self._attrib0, stride_bytes, ia) orelse break;
        const b = readVertex(vertex_buffer._bytes, self._attrib0, stride_bytes, ib) orelse break;
        const c = readVertex(vertex_buffer._bytes, self._attrib0, stride_bytes, ic) orelse break;

        const ax, const ay = clipToViewport(a, viewport_rect);
        const bx, const by = clipToViewport(b, viewport_rect);
        const cx, const cy = clipToViewport(c, viewport_rect);
        self._surface.fillTriangle(fill_color, ax, ay, bx, by, cx, cy);
    }
}

/// Enables a WebGL extension.
pub fn getExtension(_: *const WebGLRenderingContext, name: []const u8, page: *Page) !?Extension {
    const tag = Extension.find(name) orelse return null;

    return switch (tag) {
        .WEBGL_debug_renderer_info => {
            const info = try page._factory.create(Extension.Type.WEBGL_debug_renderer_info{});
            return .{ .WEBGL_debug_renderer_info = info };
        },
        .WEBGL_lose_context => {
            const ctx = try page._factory.create(Extension.Type.WEBGL_lose_context{});
            return .{ .WEBGL_lose_context = ctx };
        },
        inline else => |comptime_enum| @unionInit(Extension, @tagName(comptime_enum), {}),
    };
}

/// Returns a list of all the supported WebGL extensions.
pub fn getSupportedExtensions(_: *const WebGLRenderingContext) []const []const u8 {
    return std.meta.fieldNames(Extension.Kind);
}

fn currentViewport(self: *const WebGLRenderingContext) Viewport {
    const width = if (self._viewport_width > 0) self._viewport_width else @as(i32, @intCast(self._surface.width));
    const height = if (self._viewport_height > 0) self._viewport_height else @as(i32, @intCast(self._surface.height));
    return .{
        .x = self._viewport_x,
        .y = self._viewport_y,
        .width = width,
        .height = height,
    };
}

fn isShaderType(shader_type: u32) bool {
    return shader_type == VERTEX_SHADER or shader_type == FRAGMENT_SHADER;
}

fn parseFirstAttributeName(source: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "attribute")) |start| {
        var pos = start + "attribute".len;
        pos = skipWhitespace(source, pos);
        const type_start = pos;
        pos = consumeIdentifier(source, pos);
        if (pos == type_start) {
            cursor = start + 1;
            continue;
        }

        pos = skipWhitespace(source, pos);
        const name_start = pos;
        pos = consumeIdentifier(source, pos);
        if (pos > name_start) {
            return source[name_start..pos];
        }
        cursor = start + 1;
    }
    return null;
}

fn parseFirstUniformName(source: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "uniform")) |start| {
        var pos = start + "uniform".len;
        pos = skipWhitespace(source, pos);
        const type_start = pos;
        pos = consumeIdentifier(source, pos);
        if (pos == type_start) {
            cursor = start + 1;
            continue;
        }

        pos = skipWhitespace(source, pos);
        const name_start = pos;
        pos = consumeIdentifier(source, pos);
        if (pos > name_start) {
            return source[name_start..pos];
        }
        cursor = start + 1;
    }
    return null;
}

fn parseFirstVec4Color(source: []const u8) ?color.RGBA {
    const start = std.mem.indexOf(u8, source, "vec4(") orelse return null;
    const args_start = start + "vec4(".len;
    const args_end = std.mem.indexOfPos(u8, source, args_start, ")") orelse return null;
    const args = source[args_start..args_end];

    var tokens = std.mem.splitScalar(u8, args, ',');
    var values: [4]f64 = undefined;
    var i: usize = 0;
    while (tokens.next()) |token| {
        if (i >= values.len) return null;
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        values[i] = std.fmt.parseFloat(f64, trimmed) catch return null;
        i += 1;
    }
    if (i != values.len) return null;

    return .{
        .r = floatChannelToByte(values[0]),
        .g = floatChannelToByte(values[1]),
        .b = floatChannelToByte(values[2]),
        .a = floatChannelToByte(values[3]),
    };
}

fn programFillColor(program: *const WebGLProgram) color.RGBA {
    return program._uniform_color orelse program._fragment_color;
}

fn floatChannelToByte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255.0));
}

fn skipWhitespace(source: []const u8, start: usize) usize {
    var pos = start;
    while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
    return pos;
}

fn consumeIdentifier(source: []const u8, start: usize) usize {
    var pos = start;
    while (pos < source.len) : (pos += 1) {
        const ch = source[pos];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$') {
            continue;
        }
        break;
    }
    return pos;
}

fn readVertex(bytes: []const u8, attrib: VertexAttribState, stride_bytes: i32, vertex_index: i32) ?Vertex {
    const base = attrib.offset + vertex_index * stride_bytes;
    if (base < 0) return null;
    const x_offset = @as(usize, @intCast(base));
    const y_offset = x_offset + @sizeOf(f32);
    if (y_offset + @sizeOf(f32) > bytes.len) return null;

    return .{
        .x = readF32(bytes, x_offset),
        .y = readF32(bytes, y_offset),
    };
}

fn typedArrayBytes(value: js.Value) ![]const u8 {
    if (value.isUint8Array() or value.isUint8ClampedArray() or value.isArrayBuffer() or value.isArrayBufferView()) {
        if (value.toZig(js.TypedArray(u8))) |typed| {
            return typed.values;
        } else |_| {}
    }
    if (value.isFloat32Array()) {
        const typed = try value.toZig(js.TypedArray(f32));
        return std.mem.sliceAsBytes(typed.values);
    }
    if (value.isFloat64Array()) {
        const typed = try value.toZig(js.TypedArray(f64));
        return std.mem.sliceAsBytes(typed.values);
    }
    if (value.isUint16Array()) {
        const typed = try value.toZig(js.TypedArray(u16));
        return std.mem.sliceAsBytes(typed.values);
    }
    if (value.isInt16Array()) {
        const typed = try value.toZig(js.TypedArray(i16));
        return std.mem.sliceAsBytes(typed.values);
    }
    if (value.isUint32Array()) {
        const typed = try value.toZig(js.TypedArray(u32));
        return std.mem.sliceAsBytes(typed.values);
    }
    if (value.isInt32Array()) {
        const typed = try value.toZig(js.TypedArray(i32));
        return std.mem.sliceAsBytes(typed.values);
    }
    if (value.isInt8Array()) {
        const typed = try value.toZig(js.TypedArray(i8));
        return std.mem.sliceAsBytes(typed.values);
    }
    return error.InvalidArgument;
}

fn readElementIndex(bytes: []const u8, offset: i32, element_index: i32) ?i32 {
    const base = @as(usize, @intCast(offset)) + (@as(usize, @intCast(element_index)) * @sizeOf(u16));
    if (base + 2 > bytes.len) return null;
    const index = std.mem.readInt(u16, bytes[base .. base + 2][0..2], .little);
    return @as(i32, @intCast(index));
}

fn readF32(bytes: []const u8, offset: usize) f32 {
    const slice = bytes[offset .. offset + @sizeOf(u32)];
    const bits = std.mem.readInt(u32, slice[0..4], .little);
    return @bitCast(bits);
}

fn clipToViewport(vertex: Vertex, viewport_rect: Viewport) struct { f64, f64 } {
    const width = @as(f64, @floatFromInt(@max(viewport_rect.width, 1)));
    const height = @as(f64, @floatFromInt(@max(viewport_rect.height, 1)));
    return .{
        @as(f64, @floatFromInt(viewport_rect.x)) + ((@as(f64, vertex.x) + 1.0) * 0.5 * width),
        @as(f64, @floatFromInt(viewport_rect.y)) + ((1.0 - ((@as(f64, vertex.y) + 1.0) * 0.5)) * height),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGLRenderingContext);

    pub const Meta = struct {
        pub const name = "WebGLRenderingContext";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getParameter = bridge.function(WebGLRenderingContext.getParameter, .{});
    pub const getExtension = bridge.function(WebGLRenderingContext.getExtension, .{});
    pub const getSupportedExtensions = bridge.function(WebGLRenderingContext.getSupportedExtensions, .{});
    pub const clearColor = bridge.function(WebGLRenderingContext.clearColor, .{});
    pub const clear = bridge.function(WebGLRenderingContext.clear, .{});
    pub const createShader = bridge.function(WebGLRenderingContext.createShader, .{});
    pub const shaderSource = bridge.function(WebGLRenderingContext.shaderSource, .{});
    pub const compileShader = bridge.function(WebGLRenderingContext.compileShader, .{});
    pub const getShaderParameter = bridge.function(WebGLRenderingContext.getShaderParameter, .{});
    pub const createProgram = bridge.function(WebGLRenderingContext.createProgram, .{});
    pub const attachShader = bridge.function(WebGLRenderingContext.attachShader, .{});
    pub const linkProgram = bridge.function(WebGLRenderingContext.linkProgram, .{});
    pub const getProgramParameter = bridge.function(WebGLRenderingContext.getProgramParameter, .{});
    pub const useProgram = bridge.function(WebGLRenderingContext.useProgram, .{});
    pub const createBuffer = bridge.function(WebGLRenderingContext.createBuffer, .{});
    pub const bindBuffer = bridge.function(WebGLRenderingContext.bindBuffer, .{});
    pub const bufferData = bridge.function(WebGLRenderingContext.bufferData, .{});
    pub const getAttribLocation = bridge.function(WebGLRenderingContext.getAttribLocation, .{});
    pub const getUniformLocation = bridge.function(WebGLRenderingContext.getUniformLocation, .{});
    pub const uniform4f = bridge.function(WebGLRenderingContext.uniform4f, .{});
    pub const vertexAttribPointer = bridge.function(WebGLRenderingContext.vertexAttribPointer, .{});
    pub const enableVertexAttribArray = bridge.function(WebGLRenderingContext.enableVertexAttribArray, .{});
    pub const viewport = bridge.function(WebGLRenderingContext.viewport, .{});
    pub const drawArrays = bridge.function(WebGLRenderingContext.drawArrays, .{});
    pub const drawElements = bridge.function(WebGLRenderingContext.drawElements, .{});
    pub const drawingBufferWidth = bridge.accessor(WebGLRenderingContext.getDrawingBufferWidth, null, .{});
    pub const drawingBufferHeight = bridge.accessor(WebGLRenderingContext.getDrawingBufferHeight, null, .{});
    pub const COLOR_BUFFER_BIT = bridge.property(WebGLRenderingContext.COLOR_BUFFER_BIT, .{ .template = false, .readonly = true });
    pub const FLOAT = bridge.property(WebGLRenderingContext.FLOAT, .{ .template = false, .readonly = true });
    pub const UNSIGNED_SHORT = bridge.property(WebGLRenderingContext.UNSIGNED_SHORT, .{ .template = false, .readonly = true });
    pub const ARRAY_BUFFER = bridge.property(WebGLRenderingContext.ARRAY_BUFFER, .{ .template = false, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER = bridge.property(WebGLRenderingContext.ELEMENT_ARRAY_BUFFER, .{ .template = false, .readonly = true });
    pub const STATIC_DRAW = bridge.property(WebGLRenderingContext.STATIC_DRAW, .{ .template = false, .readonly = true });
    pub const TRIANGLES = bridge.property(WebGLRenderingContext.TRIANGLES, .{ .template = false, .readonly = true });
    pub const VERTEX_SHADER = bridge.property(WebGLRenderingContext.VERTEX_SHADER, .{ .template = false, .readonly = true });
    pub const FRAGMENT_SHADER = bridge.property(WebGLRenderingContext.FRAGMENT_SHADER, .{ .template = false, .readonly = true });
    pub const COMPILE_STATUS = bridge.property(WebGLRenderingContext.COMPILE_STATUS, .{ .template = false, .readonly = true });
    pub const LINK_STATUS = bridge.property(WebGLRenderingContext.LINK_STATUS, .{ .template = false, .readonly = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}

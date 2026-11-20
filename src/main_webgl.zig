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

//! Writes src/browser/webapi/canvas/WebGL{,2}RenderingContext.zig from the
//! WebGL IDL next to them, invoked by `zig build webgl`. Methods that return
//! nothing become bridge noops; the others map to webgl.zig.

const std = @import("std");

const Allocator = std.mem.Allocator;

const license =
    \\// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
    \\//
    \\// Francis Bouvier <francis@lightpanda.io>
    \\// Pierre Tachoire <pierre@lightpanda.io>
    \\//
    \\// This program is free software: you can redistribute it and/or modify
    \\// it under the terms of the GNU Affero General Public License as
    \\// published by the Free Software Foundation, either version 3 of the
    \\// License, or (at your option) any later version.
    \\//
    \\// This program is distributed in the hope that it will be useful,
    \\// but WITHOUT ANY WARRANTY; without even the implied warranty of
    \\// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    \\// GNU Affero General Public License for more details.
    \\//
    \\// You should have received a copy of the GNU Affero General Public License
    \\// along with this program.  If not, see <https://www.gnu.org/licenses/>.
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // executable name
    var paths: [4][]const u8 = undefined;
    for (&paths) |*path| {
        path.* = args.next() orelse {
            std.debug.print("usage: lightpanda-webgl <webgl1.idl> <webgl2.idl> <WebGLRenderingContext.zig> <WebGL2RenderingContext.zig>\n", .{});
            return error.MissingArgument;
        };
    }

    var idl: Interfaces = .empty;
    for (paths[0..2]) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        try parse(arena, &idl, text);
    }

    const contexts = [_]Context{
        .{ .name = "WebGLRenderingContext", .version = "webgl1", .idl = "webgl1.idl", .mixins = &.{ "WebGLRenderingContextBase", "WebGLRenderingContextOverloads" } },
        .{ .name = "WebGL2RenderingContext", .version = "webgl2", .idl = "webgl1.idl and webgl2.idl", .mixins = &.{ "WebGLRenderingContextBase", "WebGL2RenderingContextBase", "WebGL2RenderingContextOverloads" } },
    };
    for (contexts, paths[2..]) |context, path| {
        const source = try generate(arena, &idl, context);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source });
    }
}

const Members = struct {
    // Value, in declaration order
    consts: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // Whether every overload returns undefined
    methods: std.StringArrayHashMapUnmanaged(bool) = .empty,
};

const Interfaces = std.StringHashMapUnmanaged(Members);

const Context = struct {
    name: []const u8,
    version: []const u8,
    idl: []const u8,
    mixins: []const []const u8,
};

/// The constants and methods of each interface and mixin. Covers the subset of
/// Web IDL the WebGL specs use: no nested braces inside an interface body.
fn parse(arena: Allocator, idl: *Interfaces, raw: []const u8) !void {
    const text = try stripComments(arena, raw);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "interface ")) |start| {
        const open = std.mem.indexOfScalarPos(u8, text, start, '{') orelse return error.InvalidIdl;
        const close = std.mem.indexOfPos(u8, text, open, "};") orelse return error.InvalidIdl;
        pos = close + 2;

        var header = std.mem.tokenizeAny(u8, text[start..open], " \t\n:");
        _ = header.next(); // interface
        var name = header.next() orelse return error.InvalidIdl;
        if (std.mem.eql(u8, name, "mixin")) {
            name = header.next() orelse return error.InvalidIdl;
        }

        const gop = try idl.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try parseMembers(arena, gop.value_ptr, text[open + 1 .. close]);
    }
}

fn parseMembers(arena: Allocator, members: *Members, body: []const u8) !void {
    var statements = std.mem.splitScalar(u8, body, ';');
    while (statements.next()) |raw| {
        var statement = std.mem.trim(u8, raw, " \t\n");
        if (statement.len > 0 and statement[0] == '[') {
            const end = std.mem.indexOfScalar(u8, statement, ']') orelse return error.InvalidIdl;
            statement = std.mem.trim(u8, statement[end + 1 ..], " \t\n");
        }
        if (statement.len == 0 or std.mem.indexOf(u8, statement, "attribute") != null) {
            continue;
        }

        if (std.mem.startsWith(u8, statement, "const ")) {
            const eq = std.mem.indexOfScalar(u8, statement, '=') orelse return error.InvalidIdl;
            const name = lastWord(statement[0..eq]);
            const value = std.mem.trim(u8, statement[eq + 1 ..], " \t\n");
            const gop = try members.consts.getOrPut(arena, name);
            if (!gop.found_existing) gop.value_ptr.* = value;
            continue;
        }

        const paren = std.mem.indexOfScalar(u8, statement, '(') orelse continue;
        const before = std.mem.trimEnd(u8, statement[0..paren], " \t\n");
        const name = lastWord(before);
        const returns = std.mem.trim(u8, before[0 .. before.len - name.len], " \t\n");
        const is_void = std.mem.eql(u8, returns, "undefined");
        const gop = try members.methods.getOrPut(arena, name);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* and is_void else is_void;
    }
}

fn lastWord(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\n");
    const start = if (std.mem.lastIndexOfAny(u8, trimmed, " \t\n")) |i| i + 1 else 0;
    return trimmed[start..];
}

fn stripComments(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = (std.mem.indexOfPos(u8, text, i, "*/") orelse return error.InvalidIdl) + 2;
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.items;
}

const creates = std.StaticStringMap([]const u8).initComptime(.{
    .{ "createBuffer", "WebGLBuffer" },
    .{ "createFramebuffer", "WebGLFramebuffer" },
    .{ "createProgram", "WebGLProgram" },
    .{ "createRenderbuffer", "WebGLRenderbuffer" },
    .{ "createShader", "WebGLShader" },
    .{ "createTexture", "WebGLTexture" },
    .{ "createQuery", "WebGLQuery" },
    .{ "createSampler", "WebGLSampler" },
    .{ "createTransformFeedback", "WebGLTransformFeedback" },
    .{ "createVertexArray", "WebGLVertexArrayObject" },
    .{ "fenceSync", "WebGLSync" },
    .{ "getUniformLocation", "WebGLUniformLocation" },
});

// Value methods that share one of webgl.zig's generic ones. The rest are
// implemented there under their own name, and a missing one fails the build.
const shared = std.StaticStringMap([]const u8).initComptime(.{
    .{ "isContextLost", "no" },
    .{ "isEnabled", "no" },
    .{ "getExtension", "none" },
    .{ "getActiveAttrib", "none" },
    .{ "getActiveUniform", "none" },
    .{ "getTransformFeedbackVarying", "none" },
    .{ "getQuery", "none" },
    .{ "getIndexedParameter", "none" },
    .{ "getSupportedExtensions", "emptyList" },
    .{ "getAttachedShaders", "emptyList" },
    .{ "getUniformIndices", "emptyList" },
    .{ "getActiveUniforms", "emptyList" },
    .{ "getProgramInfoLog", "emptyString" },
    .{ "getShaderInfoLog", "emptyString" },
    .{ "getShaderSource", "emptyString" },
    .{ "getActiveUniformBlockName", "emptyString" },
    .{ "getError", "zero" },
    .{ "getAttribLocation", "zero" },
    .{ "getFragDataLocation", "zero" },
    .{ "getUniformBlockIndex", "zero" },
    .{ "getVertexAttribOffset", "zero" },
    .{ "getBufferParameter", "zero" },
    .{ "getRenderbufferParameter", "zero" },
    .{ "getTexParameter", "zero" },
    .{ "getFramebufferAttachmentParameter", "zero" },
    .{ "getUniform", "zero" },
    .{ "getSamplerParameter", "zero" },
    .{ "getActiveUniformBlockParameter", "zero" },
});

fn writeValueMethod(w: *std.Io.Writer, name: []const u8) !void {
    if (creates.get(name)) |object| {
        return w.print("M.create(webgl.{s})", .{object});
    }
    const method = shared.get(name) orelse if (std.mem.startsWith(u8, name, "is")) "isObject" else name;
    try w.print("M.{s}", .{method});
}

fn generate(arena: Allocator, idl: *const Interfaces, context: Context) ![]const u8 {
    var consts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var methods: std.StringArrayHashMapUnmanaged(bool) = .empty;
    for (context.mixins) |mixin| {
        const members = idl.get(mixin) orelse return error.MissingMixin;
        for (members.consts.keys(), members.consts.values()) |name, value| {
            const gop = try consts.getOrPut(arena, name);
            if (!gop.found_existing) gop.value_ptr.* = value;
        }
        for (members.methods.keys(), members.methods.values()) |name, is_void| {
            const gop = try methods.getOrPut(arena, name);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* and is_void else is_void;
        }
    }
    methods.sort(struct {
        keys: []const []const u8,
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, self.keys[a], self.keys[b]) == .lt;
        }
    }{ .keys = methods.keys() });

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print(
        \\{s}
        \\
        \\// Generated by `zig build webgl` (src/main_webgl.zig) from {s}.
        \\// The methods are in webgl.zig.
        \\
        \\const lp = @import("lightpanda");
        \\
        \\const webgl = @import("webgl.zig");
        \\const Canvas = @import("../element/html/Canvas.zig");
        \\
        \\const js = lp.js;
        \\
        \\const {s} = @This();
        \\
        \\_canvas: *Canvas,
        \\
        \\
    , .{ license, context.idl, context.name });
    if (std.mem.eql(u8, context.version, "webgl1")) {
        try w.print(
            \\pub fn registerTypes() []const type {{
            \\    return &([_]type{{{s}}} ++ webgl.object_types);
            \\}}
            \\
            \\
        , .{context.name});
    }
    try w.print(
        \\const M = webgl.Methods({0s}, .{1s});
        \\
        \\pub const JsApi = struct {{
        \\    pub const bridge = js.Bridge({0s});
        \\
        \\    pub const Meta = struct {{
        \\        pub const name = "{0s}";
        \\
        \\        pub var class_id: bridge.ClassId = undefined;
        \\    }};
        \\
        \\    pub const canvas = bridge.accessor(M.getCanvas, null, .{{}});
        \\    pub const drawingBufferWidth = bridge.accessor(M.getDrawingBufferWidth, null, .{{}});
        \\    pub const drawingBufferHeight = bridge.accessor(M.getDrawingBufferHeight, null, .{{}});
        \\    pub const drawingBufferFormat = bridge.accessor(M.getDrawingBufferFormat, null, .{{}});
        \\    pub const drawingBufferColorSpace = bridge.accessor(M.getColorSpace, M.setColorSpace, .{{}});
        \\    pub const unpackColorSpace = bridge.accessor(M.getColorSpace, M.setColorSpace, .{{}});
        \\
        \\
    , .{ context.name, context.version });
    for (consts.keys(), consts.values()) |name, value| {
        try w.print("pub const {f} = bridge.property({s}, .{{ .template = true }});\n", .{ std.zig.fmtId(name), value });
    }
    try w.writeByte('\n');
    for (methods.keys(), methods.values()) |name, is_void| {
        try w.print("pub const {f} = bridge.function(", .{std.zig.fmtId(name)});
        if (is_void) {
            try w.writeAll("M.noop, .{ .noop = true }");
        } else {
            try writeValueMethod(w, name);
            try w.writeAll(", .{}");
        }
        try w.writeAll(");\n");
    }
    try w.writeAll("};\n");

    return format(arena, try out.toOwnedSliceSentinel(0));
}

/// zig fmt, so the output needs no hand alignment.
fn format(arena: Allocator, source: [:0]const u8) ![]const u8 {
    var tree: std.zig.Ast = try .parse(arena, source, .{});
    if (tree.errors.len > 0) {
        var stderr: std.Io.Writer.Allocating = .init(arena);
        for (tree.errors) |err| {
            try tree.renderError(err, &stderr.writer);
            try stderr.writer.writeByte('\n');
        }
        std.debug.print("generated source doesn't parse:\n{s}", .{stderr.written()});
        return error.InvalidSource;
    }
    return tree.renderAlloc(arena);
}

// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const zlib = @import("zlib.zig");
const brotli = @import("brotli.zig");

const js = @import("../../js/js.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

pub const Format = enum {
    brotli,
    gzip,
    deflate,
    @"deflate-raw",

    pub const js_enum_from_string = true;
};

pub const Compressor = union(enum(u1)) {
    deflate: zlib.Deflate(.compress),
    brotli: brotli.EncodingStream,

    pub fn init(exec: *const Execution, format: Format) Compressor {
        return switch (format) {
            inline .deflate, .@"deflate-raw", .gzip => .{ .deflate = .init(exec, format) },
            .brotli => .{ .brotli = .init(exec) },
        };
    }

    pub fn transform(self: *Compressor, controller: *TransformStream.DefaultController, chunk: js.Value) !void {
        return switch (self.*) {
            inline else => |*compressor| compressor.transform(controller, chunk),
        };
    }

    pub fn flush(self: *Compressor, controller: *TransformStream.DefaultController) !void {
        return switch (self.*) {
            inline else => |*compressor| compressor.flush(controller),
        };
    }
};

pub const Decompressor = union(enum(u1)) {
    inflate: zlib.Deflate(.decompress),
    brotli: brotli.DecodingStream,

    pub fn init(exec: *const Execution, format: Format) Decompressor {
        return switch (format) {
            inline .deflate, .@"deflate-raw", .gzip => .{ .inflate = .init(exec, format) },
            .brotli => .{ .brotli = .init(exec) },
        };
    }

    pub fn transform(self: *Decompressor, controller: *TransformStream.DefaultController, chunk: js.Value) !void {
        return switch (self.*) {
            inline else => |*decompressor| decompressor.transform(controller, chunk),
        };
    }

    pub fn flush(self: *Decompressor, controller: *TransformStream.DefaultController) !void {
        return switch (self.*) {
            inline else => |*decompressor| decompressor.flush(controller),
        };
    }
};

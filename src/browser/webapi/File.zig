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

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Factory = @import("../Factory.zig");

const Blob = @import("Blob.zig");

const File = @This();

pub const Proto = Blob;

_proto: *Blob,
_name: []const u8,
_last_modified: i64,

pub const InitOptions = struct {
    endings: []const u8 = "transparent",
    lastModified: ?i64 = null,
    type: []const u8 = "",
};

pub fn init(
    parts_: js.Value,
    name_: js.Value,
    opts_: ?js.Value,
    exec: *js.Execution,
) !*File {
    const parts = try Blob.collectParts(parts_, exec) orelse return error.TypeError;
    const name = try name_.toStringSlice();

    const opts: InitOptions = blk: {
        const value = opts_ orelse break :blk .{};
        break :blk (try value.toZig(?InitOptions)) orelse .{};
    };

    const blob = try Blob.buildValue(parts, .{
        .type = opts.type,
        .endings = opts.endings,
    }, exec);

    const file = try Factory.chainedWithAllocator(blob._arena.allocator(), .{
        blob,
        File{
            ._proto = undefined,
            ._name = try blob._arena.dupe(u8, name),
            ._last_modified = opts.lastModified orelse @intCast(lp.datetime.milliTimestamp(.real)),
        },
    });
    file._proto._type = .{ .file = file };

    blob._arena.report();
    return file;
}

pub fn deinit(self: *File, page: *Page) void {
    self._proto.deinit(page);
}

pub fn releaseRef(self: *File, page: *Page) void {
    self._proto.releaseRef(page);
}

pub fn acquireRef(self: *File) void {
    self._proto.acquireRef();
}

pub fn structuredSerialize(self: *const File, writer: *js.StructuredWriter) !void {
    try self._proto.structuredSerialize(writer);
    writer.writeBytes(self._name);
    writer.writeUint64(@bitCast(self._last_modified));
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*File {
    const mime = try reader.readBytes();
    const data = try reader.readBytes();
    const name = try reader.readBytes();
    const last_modified = try reader.readUint64();

    const arena = try page.getPinnedArena(data.len + mime.len + name.len + 256, "Blob.clone");
    errdefer arena.release();

    const file = try Factory.chainedWithAllocator(arena.allocator(), .{
        Blob{
            ._rc = .{},
            ._arena = arena,
            ._type = undefined,
            ._slice = try arena.dupe(u8, data),
            // the serialized mime is already in normalized form; copy it verbatim
            ._mime = try arena.dupe(u8, mime),
        },
        File{
            ._proto = undefined,
            ._name = try arena.dupe(u8, name),
            ._last_modified = @bitCast(last_modified),
        },
    });
    file._proto._type = .{ .file = file };
    arena.report();
    return file;
}

pub fn getName(self: *const File) []const u8 {
    return self._name;
}

pub fn getLastModified(self: *const File) f64 {
    return @floatFromInt(self._last_modified);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(File);

    pub const Meta = struct {
        pub const name = "File";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(File.init, .{});
    pub const name = bridge.accessor(File.getName, null, .{});
    pub const lastModified = bridge.accessor(File.getLastModified, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: File" {
    try testing.htmlRunner("file.html", .{});
}

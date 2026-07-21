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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Blob = @import("Blob.zig");

const File = @This();

_proto: *Blob,
_name: []const u8,
_last_modified: i64,

pub const InitOptions = struct {
    type: []const u8 = "",
    endings: []const u8 = "transparent",
    lastModified: ?i64 = null,
};

pub fn init(
    parts_: ?[]const js.Value,
    name: []const u8,
    opts_: ?InitOptions,
    page: *Page,
) !*File {
    const opts = opts_ orelse InitOptions{};
    const blob = try Blob.init(parts_, .{
        .type = opts.type,
        .endings = opts.endings,
    }, page);

    errdefer blob.deinit(page);

    const file = try blob._arena.create(File);
    file.* = .{
        ._proto = blob,
        ._name = try blob._arena.dupe(u8, name),
        ._last_modified = opts.lastModified orelse std.Io.Clock.now(.real, lp.io).toMilliseconds(),
    };
    blob._type = .{ .file = file };

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
    const blob = try Blob.structuredDeserialize(reader, page);
    errdefer blob.deinit(page);

    const name = try reader.readBytes();
    const last_modified = try reader.readUint64();

    const file = try blob._arena.create(File);
    file.* = .{
        ._proto = blob,
        ._name = try blob._arena.dupe(u8, name),
        ._last_modified = @bitCast(last_modified),
    };
    blob._type = .{ .file = file };
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

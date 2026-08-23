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

const js = @import("../js/js.zig");

const Blob = @import("Blob.zig");
const FileReader = @import("FileReader.zig");

const Execution = js.Execution;

/// https://w3c.github.io/FileAPI/#FileReaderSync
/// A worker-only, stateless reader: the blob's bytes are already in memory, so
/// every read is just a conversion. None of them re-enters JavaScript, so the
/// output goes on the local_arena.
const FileReaderSync = @This();

_pad: bool = false,

pub fn init() FileReaderSync {
    return .{};
}

pub fn readAsArrayBuffer(_: *const FileReaderSync, blob: *Blob) !js.ArrayBuffer {
    return .{ .values = blob._slice };
}

pub fn readAsBinaryString(_: *const FileReaderSync, blob: *Blob) !js.String.OneByte {
    return .{ .bytes = blob._slice };
}

pub fn readAsText(_: *const FileReaderSync, blob: *Blob, encoding_: ?[]const u8, exec: *const Execution) ![]const u8 {
    return FileReader.decodeText(exec.local_arena, blob._slice, encoding_, blob._mime);
}

pub fn readAsDataURL(_: *const FileReaderSync, blob: *Blob, exec: *const Execution) ![]const u8 {
    const mime = if (blob._mime.len > 0) blob._mime else "application/octet-stream";
    return FileReader.encodeDataURL(exec.local_arena, mime, blob._slice);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FileReaderSync);

    pub const Meta = struct {
        pub const name = "FileReaderSync";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(FileReaderSync.init, .{});
    pub const readAsArrayBuffer = bridge.function(FileReaderSync.readAsArrayBuffer, .{});
    pub const readAsBinaryString = bridge.function(FileReaderSync.readAsBinaryString, .{});
    pub const readAsText = bridge.function(FileReaderSync.readAsText, .{});
    pub const readAsDataURL = bridge.function(FileReaderSync.readAsDataURL, .{});
};

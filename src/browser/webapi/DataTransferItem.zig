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

const File = @import("File.zig");
const Page = @import("../Page.zig");
const DataTransfer = @import("DataTransfer.zig");

const log = lp.log;

// https://html.spec.whatwg.org/multipage/dnd.html#the-datatransferitem-interface
const DataTransferItem = @This();

pub const Kind = enum { string, file };

// The owning DataTransfer. The item lives in that DataTransfer's arena and is
// handed to JS, so it forwards acquireRef/releaseRef to keep the arena alive as
// long as JS holds the item.
_data_transfer: *DataTransfer,
_kind: Kind,
// For string items: the normalized format (e.g. "text/plain").
// For file items: the File's MIME type.
_type: []const u8,
_payload: Payload,

pub const Payload = union(Kind) {
    string: []const u8,
    file: *File,
};

pub fn acquireRef(self: *DataTransferItem) void {
    self._data_transfer.acquireRef();
}

pub fn releaseRef(self: *DataTransferItem, page: *Page) void {
    self._data_transfer.releaseRef(page);
}

pub fn getKind(self: *const DataTransferItem) []const u8 {
    return switch (self._kind) {
        .string => "string",
        .file => "file",
    };
}

pub fn getType(self: *const DataTransferItem) []const u8 {
    return self._type;
}

pub fn getAsFile(self: *const DataTransferItem) ?*File {
    return switch (self._payload) {
        .file => |f| f,
        .string => null,
    };
}

// https://html.spec.whatwg.org/multipage/dnd.html#dom-datatransferitem-getasstring
// v1 invokes the callback synchronously with the string value. File items and a
// missing callback are no-ops, per spec.
pub fn getAsString(self: *const DataTransferItem, cb_: ?js.Function) !void {
    const cb = cb_ orelse return;
    const s = switch (self._payload) {
        .string => |str| str,
        .file => return,
    };
    var caught: js.TryCatch.Caught = undefined;
    cb.tryCall(void, .{s}, &caught) catch {
        log.debug(.js, "getAsString callback", .{ .caught = caught, .source = "DataTransferItem" });
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataTransferItem);

    pub const Meta = struct {
        pub const name = "DataTransferItem";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const kind = bridge.accessor(DataTransferItem.getKind, null, .{});
    pub const @"type" = bridge.accessor(DataTransferItem.getType, null, .{});
    pub const getAsFile = bridge.function(DataTransferItem.getAsFile, .{});
    pub const getAsString = bridge.function(DataTransferItem.getAsString, .{});
};

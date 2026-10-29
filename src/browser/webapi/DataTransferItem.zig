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

fn getKind(self: *const DataTransferItem) []const u8 {
    return switch (self._kind) {
        .string => "string",
        .file => "file",
    };
}

pub fn getType(self: *const DataTransferItem) []const u8 {
    return self._type;
}

fn getAsFile(self: *const DataTransferItem) ?*File {
    return switch (self._payload) {
        .file => |f| f,
        .string => null,
    };
}

// https://html.spec.whatwg.org/multipage/dnd.html#dom-datatransferitem-getasstring
// The callback runs in a queued task.
pub fn getAsString(self: *DataTransferItem, cb_: ?js.Function.Global, exec: *js.Execution) !void {
    const cb = cb_ orelse return;
    if (self._data_transfer._mode == .protected) {
        cb.release();
        return;
    }
    errdefer cb.release();

    const value = switch (self._payload) {
        .string => |str| str,
        .file => {
            // noop
            cb.release();
            return;
        },
    };

    const req = try exec._factory.create(StringRequest{
        .exec = exec,
        .callback = cb,
        .value = value,
        .data_transfer = self._data_transfer,
    });
    errdefer exec._factory.destroy(req);

    try exec.js.scheduler.add(req, StringRequest.run, 0, .{
        .name = "DataTransferItem.getAsString",
        .finalizer = StringRequest.cancelled,
    });
    // `value` lives in the DataTransfer's arena.
    self._data_transfer.acquireRef();
}

const StringRequest = struct {
    exec: *js.Execution,
    value: []const u8,
    callback: js.Function.Global,
    data_transfer: *DataTransfer,

    fn deinit(self: *StringRequest) void {
        const exec = self.exec;
        self.callback.release();
        self.data_transfer.releaseRef(exec.page);
        exec._factory.destroy(self);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *StringRequest = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn run(ctx: *anyopaque) anyerror!?u32 {
        const self: *StringRequest = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const exec = self.exec;
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        ls.toLocal(self.callback).call(void, .{self.value}) catch |err| {
            exec.page.recordJsError(err);
            log.debug(.js, "getAsString callback", .{ .err = err });
        };
        ls.local.runMicrotasks();
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataTransferItem);

    pub const Meta = struct {
        pub const name = "DataTransferItem";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const kind = bridge.accessor(DataTransferItem.getKind, null, .{});
    pub const @"type" = bridge.accessor(DataTransferItem.getType, null, .{});
    pub const getAsFile = bridge.function(DataTransferItem.getAsFile, .{});
    pub const getAsString = bridge.function(DataTransferItem.getAsString, .{});
};

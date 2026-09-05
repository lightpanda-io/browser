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

// The IO domain: reading back a file a command produced with
// `transferMode: "ReturnAsStream"` (Page.printToPDF). Drivers read until
// `eof` and then close.

const std = @import("std");

const CDP = @import("../CDP.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        read,
        close,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .read => return read(cmd),
        .close => return close(cmd),
    }
}

// Whole files held per connection, keyed by the handle handed to the client.
pub const Streams = struct {
    allocator: Allocator,
    next_handle: u32 = 1,
    map: std.AutoHashMapUnmanaged(u32, Stream) = .empty,

    const Stream = struct {
        data: []const u8,
        position: usize = 0, // position of the next read
    };

    // Takes ownership of `data`, which must have come from `self.allocator`.
    pub fn add(self: *Streams, data: []const u8) !u32 {
        const handle = self.next_handle;
        try self.map.put(self.allocator, handle, .{ .data = data });
        self.next_handle = handle + 1;
        return handle;
    }

    pub fn deinit(self: *Streams) void {
        var it = self.map.valueIterator();
        while (it.next()) |s| {
            self.allocator.free(s.data);
        }
        self.map.deinit(self.allocator);
    }
};

const DEFAULT_CHUNK: usize = 1048576;

fn read(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        handle: []const u8,
        offset: ?usize = null,
        size: ?usize = null,
    })) orelse return error.InvalidParams;

    const stream = lookup(cmd, params.handle) orelse {
        return cmd.sendError(-32000, "Invalid stream handle", .{});
    };
    const start = @min(params.offset orelse stream.position, stream.data.len);
    const end = @min(start + (params.size orelse DEFAULT_CHUNK), stream.data.len);
    stream.position = end;

    const chunk = stream.data[start..end];
    const encoder = std.base64.standard.Encoder;
    const encoded = try cmd.arena.alloc(u8, encoder.calcSize(chunk.len));
    _ = encoder.encode(encoded, chunk);
    return cmd.sendResult(.{
        .data = encoded,
        .base64Encoded = true,
        .eof = end == stream.data.len,
    }, .{});
}

fn close(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        handle: []const u8,
    })) orelse return error.InvalidParams;

    const handle = parseHandle(params.handle) orelse {
        return cmd.sendError(-32000, "Invalid stream handle", .{});
    };
    const streams = &cmd.cdp.streams;
    const entry = streams.map.fetchRemove(handle) orelse {
        return cmd.sendError(-32000, "Invalid stream handle", .{});
    };
    streams.allocator.free(entry.value.data);
    return cmd.sendResult(null, .{});
}

fn lookup(cmd: *CDP.Command, handle: []const u8) ?*Streams.Stream {
    const key = parseHandle(handle) orelse return null;
    return cmd.cdp.streams.map.getPtr(key);
}

fn parseHandle(handle: []const u8) ?u32 {
    return std.fmt.parseInt(u32, handle, 10) catch null;
}

// Exercised end to end by "cdp.frame: printToPDF" in page.zig.
const testing = @import("../testing.zig");
test "cdp.io: unknown handles" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "IO.read", .params = .{ .handle = "42" } });
    try ctx.expectSentError(-32000, "Invalid stream handle", .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "IO.close", .params = .{ .handle = "nope" } });
    try ctx.expectSentError(-32000, "Invalid stream handle", .{ .id = 2 });
}

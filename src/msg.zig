// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

/// MsgBuffer returns messages from a raw text read stream,
/// according to the following format `<msg_size>:<msg>`.
/// It handles both:
/// - combined messages in one read
/// - single message in several reads (multipart)
/// It's safe (and a good practice) to reuse the same MsgBuffer
/// on several reads of the same stream.
pub const MsgBuffer = struct {
    size: usize = 0,
    buf: []u8,
    pos: usize = 0,

    const MaxSize = 1024 * 1024; // 1MB

    pub fn init(alloc: std.mem.Allocator, size: usize) std.mem.Allocator.Error!MsgBuffer {
        const buf = try alloc.alloc(u8, size);
        return .{ .buf = buf };
    }

    pub fn deinit(self: MsgBuffer, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    fn isFinished(self: *MsgBuffer) bool {
        return self.pos >= self.size;
    }

    fn isEmpty(self: MsgBuffer) bool {
        return self.size == 0 and self.pos == 0;
    }

    fn reset(self: *MsgBuffer) void {
        self.size = 0;
        self.pos = 0;
    }

    // read input
    pub fn read(self: *MsgBuffer, alloc: std.mem.Allocator, input: []const u8) !struct {
        msg: []const u8,
        left: []const u8,
    } {
        var _input = input; // make input writable

        // msg size
        var msg_size: usize = undefined;
        if (self.isEmpty()) {
            // parse msg size metadata
            const size_pos = std.mem.indexOfScalar(u8, _input, ':') orelse return error.InputWithoutSize;
            const size_str = _input[0..size_pos];
            msg_size = try std.fmt.parseInt(u32, size_str, 10);
            _input = _input[size_pos + 1 ..];
        } else {
            msg_size = self.size;
        }

        // multipart
        const is_multipart = !self.isEmpty() or _input.len < msg_size;
        if (is_multipart) {

            // set msg size on empty MsgBuffer
            if (self.isEmpty()) {
                self.size = msg_size;
            }

            // get the new position of the cursor
            const new_pos = self.pos + _input.len;

            // check max limit size
            if (new_pos > MaxSize) {
                return error.MsgTooBig;
            }

            // check if the current input can fit in MsgBuffer
            if (new_pos > self.buf.len) {
                // we want to realloc at least:
                // - a size big enough to fit the entire input (ie. new_pos)
                // - a size big enough (ie. current msg size + starting buffer size)
                // to avoid multiple reallocation
                const new_size = @max(self.buf.len + self.size, new_pos);
                // resize the MsgBuffer to fit
                self.buf = try alloc.realloc(self.buf, new_size);
            }

            // copy the current input into MsgBuffer
            @memcpy(self.buf[self.pos..new_pos], _input[0..]);

            // set the new cursor position
            self.pos = new_pos;

            // if multipart is not finished, go fetch the next input
            if (!self.isFinished()) return error.MsgMultipart;

            // otherwhise multipart is finished, use its buffer as input
            _input = self.buf[0..self.pos];
            self.reset();
        }

        // handle several JSON msg in 1 read
        return .{ .msg = _input[0..msg_size], .left = _input[msg_size..] };
    }
};

fn doTest(nb: *u8) void {
    nb.* += 1;
}

test "MsgBuffer" {
    const Case = struct {
        input: []const u8,
        nb: u8,
    };
    const alloc = std.testing.allocator;
    const cases = [_]Case{
        // simple
        .{ .input = "2:ok", .nb = 1 },
        // combined
        .{ .input = "2:ok3:foo7:bar2:ok", .nb = 3 }, // "bar2:ok" is a message, no need to escape "2:" here
        // multipart
        .{ .input = "9:multi", .nb = 0 },
        .{ .input = "part", .nb = 1 },
        // multipart & combined
        .{ .input = "9:multi", .nb = 0 },
        .{ .input = "part2:ok", .nb = 2 },
        // multipart & combined with other multipart
        .{ .input = "9:multi", .nb = 0 },
        .{ .input = "part8:co", .nb = 1 },
        .{ .input = "mbined", .nb = 1 },
        // several multipart
        .{ .input = "23:multi", .nb = 0 },
        .{ .input = "several", .nb = 0 },
        .{ .input = "complex", .nb = 0 },
        .{ .input = "part", .nb = 1 },
        // combined & multipart
        .{ .input = "2:ok9:multi", .nb = 1 },
        .{ .input = "part", .nb = 1 },
    };
    var msg_buf = try MsgBuffer.init(alloc, 10);
    defer msg_buf.deinit(alloc);
    for (cases) |case| {
        var nb: u8 = 0;
        var input: []const u8 = case.input;
        while (input.len > 0) {
            const parts = msg_buf.read(alloc, input) catch |err| {
                if (err == error.MsgMultipart) break; // go to the next case input
                return err;
            };
            nb += 1;
            input = parts.left;
        }
        try std.testing.expect(nb == case.nb);
    }
}

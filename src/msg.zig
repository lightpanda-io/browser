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

pub const MsgSize = 16 * 1204; // 16KB
pub const HeaderSize = 2;
pub const MaxSize = HeaderSize + MsgSize;

pub const Msg = struct {
    pub fn getSize(data: []const u8) usize {
        return std.mem.readInt(u16, data[0..HeaderSize], .little);
    }

    pub fn setSize(len: usize, header: *[2]u8) void {
        std.mem.writeInt(u16, header, @intCast(len), .little);
    }
};

/// Buffer returns messages from a raw text read stream,
/// with the message size being encoded on the 2 first bytes (little endian)
/// It handles both:
/// - combined messages in one read
/// - single message in several reads (multipart)
/// It's safe (and a good practice) to reuse the same Buffer
/// on several reads of the same stream.
pub const Buffer = struct {
    buf: []u8,
    size: usize = 0,
    pos: usize = 0,

    fn isFinished(self: *const Buffer) bool {
        return self.pos >= self.size;
    }

    fn isEmpty(self: *const Buffer) bool {
        return self.size == 0 and self.pos == 0;
    }

    fn reset(self: *Buffer) void {
        self.size = 0;
        self.pos = 0;
    }

    // read input
    pub fn read(self: *Buffer, input: []const u8) !struct {
        msg: []const u8,
        left: []const u8,
    } {
        var _input = input; // make input writable

        // msg size
        var msg_size: usize = undefined;
        if (self.isEmpty()) {
            // decode msg size header
            msg_size = Msg.getSize(_input);
            _input = _input[HeaderSize..];
        } else {
            msg_size = self.size;
        }

        // multipart
        const is_multipart = !self.isEmpty() or _input.len < msg_size;
        if (is_multipart) {

            // set msg size on empty Buffer
            if (self.isEmpty()) {
                self.size = msg_size;
            }

            // get the new position of the cursor
            const new_pos = self.pos + _input.len;

            // check max limit size
            if (new_pos > MaxSize) {
                return error.MsgTooBig;
            }

            // copy the current input into Buffer
            // NOTE: we could use @memcpy but it's not Thread-safe (alias problem)
            // see https://www.openmymind.net/Zigs-memcpy-copyForwards-and-copyBackwards/
            // Intead we just use std.mem.copyForwards
            std.mem.copyForwards(u8, self.buf[self.pos..new_pos], _input[0..]);

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

test "Buffer" {
    const Case = struct {
        input: []const u8,
        nb: u8,
    };

    const cases = [_]Case{
        // simple
        .{ .input = .{ 2, 0 } ++ "ok", .nb = 1 },
        // combined
        .{ .input = .{ 2, 0 } ++ "ok" ++ .{ 3, 0 } ++ "foo", .nb = 2 },
        // multipart
        .{ .input = .{ 9, 0 } ++ "multi", .nb = 0 },
        .{ .input = "part", .nb = 1 },
        // multipart & combined
        .{ .input = .{ 9, 0 } ++ "multi", .nb = 0 },
        .{ .input = "part" ++ .{ 2, 0 } ++ "ok", .nb = 2 },
        // multipart & combined with other multipart
        .{ .input = .{ 9, 0 } ++ "multi", .nb = 0 },
        .{ .input = "part" ++ .{ 8, 0 } ++ "co", .nb = 1 },
        .{ .input = "mbined", .nb = 1 },
        // several multipart
        .{ .input = .{ 23, 0 } ++ "multi", .nb = 0 },
        .{ .input = "several", .nb = 0 },
        .{ .input = "complex", .nb = 0 },
        .{ .input = "part", .nb = 1 },
        // combined & multipart
        .{ .input = .{ 2, 0 } ++ "ok" ++ .{ 9, 0 } ++ "multi", .nb = 1 },
        .{ .input = "part", .nb = 1 },
    };

    var b: [MaxSize]u8 = undefined;
    var buf = Buffer{ .buf = &b };

    for (cases) |case| {
        var nb: u8 = 0;
        var input = case.input;
        while (input.len > 0) {
            const parts = buf.read(input) catch |err| {
                if (err == error.MsgMultipart) break; // go to the next case input
                return err;
            };
            nb += 1;
            input = parts.left;
        }
        try std.testing.expect(nb == case.nb);
    }
}

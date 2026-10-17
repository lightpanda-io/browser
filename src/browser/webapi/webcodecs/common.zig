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

// Helpers shared by the WebCodecs interfaces.

const js = @import("../../js/js.zig");

// The `transfer` member of the WebCodecs init dictionaries. Checked before
// anything is copied, and detached once the copy is made.
pub const Transfer = struct {
    buffers: []const js.Value,

    // DataCloneError for a duplicate or an already detached ArrayBuffer.
    pub fn check(self: Transfer) !void {
        for (self.buffers, 0..) |buffer, i| {
            if (buffer.isArrayBuffer() == false) {
                return error.TypeError;
            }
            if (isDetached(buffer)) {
                return error.DataClone;
            }
            for (self.buffers[0..i]) |previous| {
                if (previous.strictEquals(buffer)) {
                    return error.DataClone;
                }
            }
        }
    }

    // We always copy the data, so transferring is just detaching.
    pub fn detach(self: Transfer) !void {
        for (self.buffers) |buffer| {
            // ArrayBuffer.prototype.transfer() detaches the receiver. The
            // new buffer it returns is simply dropped.
            _ = try buffer.toObject().callMethod(js.Value, "transfer", .{@as(u32, 0)});
        }
    }

    fn isDetached(buffer: js.Value) bool {
        const detached = buffer.toObject().get("detached") catch return false;
        return detached.isTrue();
    }
};

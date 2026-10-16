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

const std = @import("std");

const js = @import("../../js/js.zig");

// WebIDL [EnforceRange]: we take such members as f64 since our integer
// conversion wraps (ToInt32 and friends) instead of throwing.
pub fn enforceRange(comptime T: type, value: f64) !T {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
    const truncated = @trunc(value);
    const min: f64 = switch (T) {
        u32 => 0,
        u64 => 0,
        i64 => -9007199254740991,
        else => @compileError("unsupported [EnforceRange] type"),
    };
    const max: f64 = switch (T) {
        u32 => 4294967295,
        u64, i64 => 9007199254740991,
        else => unreachable,
    };
    if (truncated < min or truncated > max) {
        return error.TypeError;
    }
    return @intFromFloat(truncated);
}

pub fn optionalEnforceRange(comptime T: type, value: ?f64) !?T {
    return try enforceRange(T, value orelse return null);
}

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

const testing = std.testing;
test "webcodecs: enforceRange" {
    try testing.expectEqual(@as(u32, 5), try enforceRange(u32, 5.9));
    try testing.expectEqual(@as(i64, -10), try enforceRange(i64, -10));
    try testing.expectError(error.TypeError, enforceRange(u32, -1));
    try testing.expectError(error.TypeError, enforceRange(u32, 4294967296));
    try testing.expectError(error.TypeError, enforceRange(i64, std.math.nan(f64)));
    try testing.expectError(error.TypeError, enforceRange(u64, std.math.inf(f64)));
}

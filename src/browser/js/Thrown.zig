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

const js = @import("js.zig");

const v8 = js.v8;
const Allocator = std.mem.Allocator;

// An exception that escaped to the top: the thrown value, and the message V8
// captured at the throw when there is one (js.TryCatch.thrown, the isolate's
// message listener).
const Thrown = @This();

value: js.Value,
message: ?*const v8.Message = null,

// Where it was thrown, and whether it's muted. The message captured at the
// throw knows the script that threw, whatever the value. Without one, it's
// rebuilt from the value: V8 uses the stack an Error captured when it was
// created, or else the current stack, so a value with no stack of its own
// (`throw {}`, an Error-like object) gets no location and isn't muted.
pub fn errorLocation(self: Thrown, allocator: Allocator) !js.Value.ErrorLocation {
    const l = self.value.local;
    const message = self.message orelse
        v8.v8__Exception__CreateMessage(l.isolate.handle, self.value.handle) orelse
        return .{};

    var location: js.Value.ErrorLocation = .{ .muted = v8.v8__Message__IsOpaque(message) };
    const line = v8.v8__Message__GetLineNumber(message, l.handle);
    if (line > 0) {
        location.line = @intCast(line);
    }
    // V8's column is 0-based.
    const column = v8.v8__Message__GetStartColumn(message);
    if (column >= 0) {
        location.column = @intCast(column + 1);
    }
    if (v8.v8__Message__GetScriptResourceName(message)) |handle| {
        const name: js.Value = .{ .local = l, .handle = handle };
        if (name.isString()) |str| {
            location.url = try str.toSliceWithAlloc(allocator);
        }
    }
    return location;
}

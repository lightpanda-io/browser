// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const MediaError = @This();

_code: u16,
_message: []const u8 = "",

pub fn init(code: u16, message: []const u8, page: *Page) !*MediaError {
    return page.arena.create(MediaError{
        ._code = code,
        ._message = try page.dupeString(message),
    });
}

pub fn getCode(self: *const MediaError) u16 {
    return self._code;
}

pub fn getMessage(self: *const MediaError) []const u8 {
    return self._message;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaError);

    pub const Meta = struct {
        pub const name = "MediaError";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Error code constants
    pub const MEDIA_ERR_ABORTED = bridge.property(1);
    pub const MEDIA_ERR_NETWORK = bridge.property(2);
    pub const MEDIA_ERR_DECODE = bridge.property(3);
    pub const MEDIA_ERR_SRC_NOT_SUPPORTED = bridge.property(4);

    pub const code = bridge.accessor(MediaError.getCode, null, .{});
    pub const message = bridge.accessor(MediaError.getMessage, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaError" {
    try testing.htmlRunner("media/mediaerror.html", .{});
}

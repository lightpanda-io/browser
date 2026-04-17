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

const js = @import("../js/js.zig");
const Session = @import("../Session.zig");

// This type is only included when the binary is built with the -Dwpt_extensions flag
const WebDriver = @This();

_pad: bool = false,

pub fn deleteAllCookies(_: *const WebDriver, session: *Session) void {
    session.cookie_jar.clearRetainingCapacity();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebDriver);

    pub const Meta = struct {
        pub const name = "WebDriver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const deleteAllCookies = bridge.function(WebDriver.deleteAllCookies, .{});
};

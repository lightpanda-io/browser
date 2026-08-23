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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const GeolocationPositionError = @This();

pub const Code = enum(u16) {
    permission_denied = 1,
    position_unavailable = 2,
    timeout = 3,

    // Chrome's wording; some pages show it verbatim.
    fn message(self: Code) []const u8 {
        return switch (self) {
            .permission_denied => "User denied Geolocation",
            .position_unavailable => "Position unavailable",
            .timeout => "Timeout expired",
        };
    }
};

_rc: lp.RC = .{},
_code: Code,
_arena: *lp.Arena,

pub fn init(exec: *js.Execution, code: Code) !*GeolocationPositionError {
    const arena = try exec.getArena(.tiny, "GeolocationPositionError");
    errdefer arena.release();

    const self = try arena.create(GeolocationPositionError);
    self.* = .{ ._arena = arena, ._code = code };
    return self;
}

pub fn deinit(self: *GeolocationPositionError, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *GeolocationPositionError) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *GeolocationPositionError, page: *Page) void {
    self._rc.release(self, page);
}

fn getCode(self: *const GeolocationPositionError) u16 {
    return @intFromEnum(self._code);
}

fn getMessage(self: *const GeolocationPositionError) []const u8 {
    return self._code.message();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GeolocationPositionError);

    pub const Meta = struct {
        pub const name = "GeolocationPositionError";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const code = bridge.accessor(GeolocationPositionError.getCode, null, .{});
    pub const message = bridge.accessor(GeolocationPositionError.getMessage, null, .{});

    pub const PERMISSION_DENIED = bridge.property(@intFromEnum(Code.permission_denied), .{ .template = true });
    pub const POSITION_UNAVAILABLE = bridge.property(@intFromEnum(Code.position_unavailable), .{ .template = true });
    pub const TIMEOUT = bridge.property(@intFromEnum(Code.timeout), .{ .template = true });
};

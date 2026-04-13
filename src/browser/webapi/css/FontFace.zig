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
const lp = @import("lightpanda");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Session = @import("../../Session.zig");

const Allocator = std.mem.Allocator;

const FontFace = @This();

pub const Status = enum {
    unloaded,
    loading,
    loaded,
    @"error",

    pub fn toStr(self: Status) []const u8 {
        return switch (self) {
            .unloaded => "unloaded",
            .loading => "loading",
            .loaded => "loaded",
            .@"error" => "error",
        };
    }
};

_rc: lp.RC(u8) = .{},
_arena: Allocator,
_family: []const u8,
_source: []const u8,
_status: Status,

pub fn init(family: []const u8, source: []const u8, page: *Page) !*FontFace {
    const arena = try page.getArena(.tiny, "FontFace");
    errdefer page.releaseArena(arena);

    const self = try arena.create(FontFace);
    self.* = .{
        ._arena = arena,
        ._family = try arena.dupe(u8, family),
        ._source = try arena.dupe(u8, source),
        ._status = .unloaded,
    };
    return self;
}

pub fn deinit(self: *FontFace, session: *Session) void {
    session.releaseArena(self._arena);
}

pub fn releaseRef(self: *FontFace, session: *Session) void {
    self._rc.release(self, session);
}

pub fn acquireRef(self: *FontFace) void {
    self._rc.acquire();
}

pub fn getFamily(self: *const FontFace) []const u8 {
    return self._family;
}

pub fn getStatus(self: *const FontFace) []const u8 {
    return self._status.toStr();
}

// load() - transitions status to loading then loaded.
// Actual network fetch deferred until TextShaper is wired in.
pub fn load(self: *FontFace, page: *Page) !js.Promise {
    self._status = .loading;
    self._status = .loaded;
    return page.js.local.?.resolvePromise({});
}

// loaded - returns a resolved Promise once status is loaded.
pub fn getLoaded(self: *FontFace, page: *Page) !js.Promise {
    if (self._status != .loaded) {
        _ = try self.load(page);
    }
    return page.js.local.?.resolvePromise({});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFace);

    pub const Meta = struct {
        pub const name = "FontFace";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FontFace.init, .{});
    pub const family = bridge.accessor(FontFace.getFamily, null, .{});
    pub const status = bridge.accessor(FontFace.getStatus, null, .{});
    pub const style = bridge.property("normal", .{ .template = false, .readonly = true });
    pub const weight = bridge.property("normal", .{ .template = false, .readonly = true });
    pub const stretch = bridge.property("normal", .{ .template = false, .readonly = true });
    pub const unicodeRange = bridge.property("U+0-10FFFF", .{ .template = false, .readonly = true });
    pub const variant = bridge.property("normal", .{ .template = false, .readonly = true });
    pub const featureSettings = bridge.property("normal", .{ .template = false, .readonly = true });
    pub const display = bridge.property("auto", .{ .template = false, .readonly = true });
    pub const loaded = bridge.accessor(FontFace.getLoaded, null, .{});
    pub const load = bridge.function(FontFace.load, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFace" {
    try testing.htmlRunner("css/font_face.html", .{});
}

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
const FontFace = @import("FontFace.zig");
const EventTarget = @import("../EventTarget.zig");
const Event = @import("../Event.zig");

const Allocator = std.mem.Allocator;

const FontFaceSet = @This();

_rc: lp.RC(u8) = .{},
_proto: *EventTarget,
_arena: Allocator,
_faces: std.ArrayList(*FontFace) = .empty,

pub fn init(page: *Page) !*FontFaceSet {
    const arena = try page.getArena(.tiny, "FontFaceSet");
    errdefer page.releaseArena(arena);

    return page._factory.eventTargetWithAllocator(arena, FontFaceSet{
        ._proto = undefined,
        ._arena = arena,
        ._faces = .empty,
    });
}

pub fn deinit(self: *FontFaceSet, session: *Session) void {
    session.releaseArena(self._arena);
}

pub fn releaseRef(self: *FontFaceSet, session: *Session) void {
    self._rc.release(self, session);
}

pub fn acquireRef(self: *FontFaceSet) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *FontFaceSet) *EventTarget {
    return self._proto;
}

pub fn getSize(self: *const FontFaceSet) u32 {
    return @intCast(self._faces.items.len);
}

pub fn getStatus(self: *const FontFaceSet) []const u8 {
    for (self._faces.items) |face| {
        if (face._status == .loading) return "loading";
    }
    return "loaded";
}

// FontFaceSet.ready - returns an already-resolved Promise.
pub fn getReady(_: *FontFaceSet, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise({});
}

// check(font, text?) - returns true if any added face's family appears in the font string.
pub fn check(self: *const FontFaceSet, font: []const u8) bool {
    if (self._faces.items.len == 0) return true;
    for (self._faces.items) |face| {
        if (std.mem.indexOf(u8, font, face._family) != null) return true;
    }
    return false;
}

// load(font, text?) - triggers loading of matching unloaded faces.
pub fn load(self: *FontFaceSet, font: []const u8, page: *Page) !js.Promise {
    const target = self.asEventTarget();

    if (page._event_manager.hasDirectListeners(target, "loading", null)) {
        const event = try Event.initTrusted(comptime .wrap("loading"), .{}, page);
        try page._event_manager.dispatchDirect(target, event, null, .{ .context = "load font face set" });
    }

    for (self._faces.items) |face| {
        if (face._status == .unloaded) {
            if (std.mem.indexOf(u8, font, face._family) != null) {
                _ = try face.load(page);
            }
        }
    }

    if (page._event_manager.hasDirectListeners(target, "loadingdone", null)) {
        const event = try Event.initTrusted(comptime .wrap("loadingdone"), .{}, page);
        try page._event_manager.dispatchDirect(target, event, null, .{ .context = "load font face set" });
    }

    return page.js.local.?.resolvePromise({});
}

// add(fontFace) - stores the face in the set.
pub fn add(self: *FontFaceSet, face: *FontFace) !*FontFaceSet {
    try self._faces.append(self._arena, face);
    return self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const status = bridge.accessor(FontFaceSet.getStatus, null, .{});
    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
    pub const add = bridge.function(FontFaceSet.add, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}

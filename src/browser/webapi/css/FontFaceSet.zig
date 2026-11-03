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
const Frame = @import("../../Frame.zig");

const Tokenizer = @import("../../css/Tokenizer.zig");
const EventTarget = @import("../EventTarget.zig");

const FontFace = @import("FontFace.zig");

const FontFaceSet = @This();

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_proto: *EventTarget,
_arena: *lp.Arena,
_faces: std.ArrayList(*FontFace) = .empty,

pub fn init(frame: *Frame) !*FontFaceSet {
    const arena = try frame.getArena(.tiny, "FontFaceSet");
    errdefer arena.release();

    return frame._factory.eventTargetWithAllocator(arena.allocator(), FontFaceSet{
        ._proto = undefined,
        ._arena = arena,
    });
}

pub fn deinit(self: *FontFaceSet, page: *Page) void {
    for (self._faces.items) |face| {
        face.releaseRef(page);
    }
    page.event_listeners.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn releaseRef(self: *FontFaceSet, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFaceSet) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *FontFaceSet) *EventTarget {
    return self._proto;
}

// FontFaceSet.ready - returns an already-resolved Promise.
// In a headless browser there is no font loading, so fonts are always ready.
pub fn getReady(_: *FontFaceSet, frame: *Frame) !js.Promise {
    return frame.js.local.?.resolvePromise({});
}

// Faces passed to add(), plus a stand-in for each family load() was asked for.
fn getSize(self: *const FontFaceSet) u32 {
    return @intCast(self._faces.items.len);
}

// check(font, text?) - always true; headless has no real fonts to check.
pub fn check(_: *const FontFaceSet, font: []const u8) bool {
    _ = font;
    return true;
}

// We don't read @font-face rules, but chances are that a page waiting on a
// family did declare it. This could delay/block the site, so we'll answer
// each unique family with a FontFace.
pub fn load(self: *FontFaceSet, font: []const u8, frame: *Frame) !js.Promise {
    var matched: std.ArrayList(*FontFace) = .empty;

    var it = FamilyIterator.init(font);
    while (it.next()) |family| {
        var found = false;
        for (self._faces.items) |face| {
            if (std.ascii.eqlIgnoreCase(face._family, family) == false) {
                continue;
            }

            found = true;
            if (std.mem.findScalar(*FontFace, matched.items, face) == null) {
                try matched.append(frame.call_arena, face);
            }
        }
        if (found == false) {
            const face = try FontFace.init(family, "", frame);
            try self.hold(face);
            try matched.append(frame.call_arena, face);
        }
    }
    return frame.js.local.?.resolvePromise(matched.items);
}

// traced so that load() returns it for its family. Nothing actually loads.
pub fn add(self: *FontFaceSet, face: *FontFace) !*FontFaceSet {
    if (std.mem.findScalar(*FontFace, self._faces.items, face) == null) {
        try self.hold(face);
    }
    return self;
}

fn hold(self: *FontFaceSet, face: *FontFace) !void {
    try self._faces.append(self._arena.allocator(), face);
    face.acquireRef();
}

// The family names in a CSS font shorthand, e.g. "italic 16px/1.5 'Open Sans',
// serif": the comma-separated list after the size and line-height, minus
// generic families.
const FamilyIterator = struct {
    tokenizer: Tokenizer,
    done: bool = false,

    fn init(font: []const u8) FamilyIterator {
        var tokenizer: Tokenizer = .{ .input = font };
        skipToFamilies(&tokenizer);
        return .{ .tokenizer = tokenizer };
    }

    fn next(self: *FamilyIterator) ?[]const u8 {
        while (self.done == false) {
            if (self.entry()) |name| {
                return name;
            }
        }
        return null;
    }

    // Consumes one entry, up to the next comma: a string, or idents for an
    // unquoted name ("Open Sans"). Null when it isn't a family name.
    fn entry(self: *FamilyIterator) ?[]const u8 {
        const t = &self.tokenizer;
        var string: ?[]const u8 = null;
        var idents: usize = 0;
        var start: usize = 0;
        var end: usize = 0;
        var valid = true;
        while (true) {
            const pos = t.position;
            const token = t.next() orelse {
                self.done = true;
                break;
            };
            switch (token) {
                .white_space, .comment => {},
                .comma => break,
                .string => |value| {
                    valid = valid and string == null and idents == 0;
                    string = value;
                },
                .ident => {
                    valid = valid and string == null;
                    if (idents == 0) {
                        start = pos;
                    }
                    end = t.position;
                    idents += 1;
                },
                else => valid = false,
            }
        }

        if (valid == false) {
            return null;
        }
        if (string) |value| {
            // Quoted: a family name even if it spells a generic one.
            return if (value.len == 0) null else value;
        }
        if (idents == 0) {
            return null;
        }
        const name = t.input[start..end];
        if (idents == 1 and isGenericFamily(name)) {
            return null;
        }
        return name;
    }
};

// Style, variant, weight and stretch come before the size, and an optional
// "/line-height" after it. Leaves the tokenizer at the end when there's no size.
fn skipToFamilies(t: *Tokenizer) void {
    while (nextSignificant(t)) |token| {
        const is_size = switch (token) {
            .dimension, .percentage => true,
            .ident => |name| isSizeKeyword(name),
            else => false,
        };
        if (is_size == false) {
            continue;
        }

        const after_size = t.position;
        if (nextSignificant(t)) |after| {
            if (after == .delim and after.delim == '/') {
                _ = nextSignificant(t);
                return;
            }
        }
        t.position = after_size;
        return;
    }
}

fn nextSignificant(t: *Tokenizer) ?Tokenizer.Token {
    while (t.next()) |token| {
        switch (token) {
            .white_space, .comment => {},
            else => return token,
        }
    }
    return null;
}

fn isSizeKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large", "larger", "smaller" };
    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(name, keyword)) {
            return true;
        }
    }
    return false;
}

fn isGenericFamily(name: []const u8) bool {
    const generics = [_][]const u8{ "serif", "sans-serif", "cursive", "fantasy", "monospace", "system-ui", "emoji", "math", "fangsong", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded" };
    for (generics) |generic| {
        if (std.ascii.eqlIgnoreCase(name, generic)) {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const status = bridge.property("loaded", .{ .template = false, .readonly = true });
    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
    pub const add = bridge.function(FontFaceSet.add, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}

test "FontFaceSet: font shorthand families" {
    const cases = [_]struct { font: []const u8, families: []const []const u8 }{
        .{ .font = "16px Roboto", .families = &.{"Roboto"} },
        .{ .font = "italic bold 16px/1.5 'Open Sans', serif", .families = &.{"Open Sans"} },
        .{ .font = "normal 400 100px \"A, B\", C", .families = &.{ "A, B", "C" } },
        .{ .font = "16px / 1.5 Foo", .families = &.{"Foo"} },
        .{ .font = "16px/ 1.5 Foo", .families = &.{"Foo"} },
        .{ .font = "16px/normal Open Sans , /* c */ Foo", .families = &.{ "Open Sans", "Foo" } },
        .{ .font = "16px Foo, 12, Bar", .families = &.{ "Foo", "Bar" } },
        .{ .font = "50% Foo", .families = &.{"Foo"} },
        .{ .font = "large \"serif\", sans-serif", .families = &.{"serif"} },
        .{ .font = "16px sans-serif", .families = &.{} },
        .{ .font = "bold Roboto", .families = &.{} },
        .{ .font = "", .families = &.{} },
    };
    for (cases) |case| {
        var it = FamilyIterator.init(case.font);
        for (case.families) |expected| {
            try testing.expectEqual(expected, it.next().?);
        }
        try testing.expectEqual(null, it.next());
    }
}

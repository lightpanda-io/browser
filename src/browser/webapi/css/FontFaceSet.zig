const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");

const FontFaceSet = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,
_page: *Page,

pub fn init(page: *Page) !*FontFaceSet {
    return page._factory.create(FontFaceSet{
        ._page = page,
    });
}

pub fn getReady(_: *FontFaceSet, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise({});
}

pub fn getSize(self: *const FontFaceSet) !u32 {
    const faces = try self.collectFontFaces(self._page);
    return @intCast(faces.len);
}

pub fn getStatus(_: *const FontFaceSet) []const u8 {
    return "loaded";
}

pub fn check(self: *const FontFaceSet, font: []const u8, text: ?[]const u8) bool {
    _ = text;
    const family = parseRequestedFamily(font) orelse return true;
    if (isGenericFontFamily(family)) {
        return true;
    }
    const faces = self.collectFontFaces(self._page) catch return false;
    for (faces) |entry| {
        if (entry.loaded and std.ascii.eqlIgnoreCase(entry.family, family)) {
            return true;
        }
    }
    return false;
}

pub fn load(self: *FontFaceSet, font: []const u8, text: ?[]const u8, page: *Page) !js.Promise {
    _ = text;
    const requested_family = parseRequestedFamily(font);
    const faces = try self.collectFontFaces(page);
    var arr = page.js.local.?.newArray(@intCast(countMatchingLoadedFaces(faces, requested_family)));
    var index: u32 = 0;
    for (faces) |entry| {
        if (!matchesRequestedFamily(requested_family, entry)) {
            continue;
        }
        _ = try arr.set(index, entry.family, .{});
        index += 1;
    }
    return page.js.local.?.resolvePromise(arr.toValue());
}

fn collectFontFaces(self: *const FontFaceSet, page: *Page) ![]const CSSStyleSheet.FontFaceEntry {
    _ = self;
    const sheets = try page.window._document.getStyleSheets(page);
    var entries: std.ArrayList(CSSStyleSheet.FontFaceEntry) = .{};
    defer entries.deinit(page.call_arena);
    for (sheets.items()) |sheet| {
        try entries.appendSlice(page.call_arena, sheet.getFontFaces());
    }
    return try page.call_arena.dupe(CSSStyleSheet.FontFaceEntry, entries.items);
}

fn countMatchingLoadedFaces(
    faces: []const CSSStyleSheet.FontFaceEntry,
    requested_family: ?[]const u8,
) usize {
    var count: usize = 0;
    for (faces) |entry| {
        if (matchesRequestedFamily(requested_family, entry)) {
            count += 1;
        }
    }
    return count;
}

fn matchesRequestedFamily(requested_family: ?[]const u8, entry: CSSStyleSheet.FontFaceEntry) bool {
    if (!entry.loaded) {
        return false;
    }
    const family = requested_family orelse return true;
    return std.ascii.eqlIgnoreCase(family, entry.family);
}

fn parseRequestedFamily(font: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, font, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return null;
    }

    for ([_]u8{ '"', '\'' }) |quote| {
        const start = std.mem.indexOfScalar(u8, trimmed, quote) orelse continue;
        const end = std.mem.lastIndexOfScalar(u8, trimmed, quote) orelse continue;
        if (end > start) {
            const family = std.mem.trim(u8, trimmed[start + 1 .. end], &std.ascii.whitespace);
            if (family.len != 0) {
                return family;
            }
        }
    }

    const comma = std.mem.indexOfScalar(u8, trimmed, ',') orelse trimmed.len;
    const head = std.mem.trim(u8, trimmed[0..comma], &std.ascii.whitespace);
    if (head.len == 0) {
        return null;
    }
    const separators = &std.ascii.whitespace;
    var family_start: usize = 0;
    for (separators) |separator| {
        if (std.mem.lastIndexOfScalar(u8, head, separator)) |idx| {
            family_start = @max(family_start, idx + 1);
        }
    }
    const family = std.mem.trim(u8, head[family_start..], &std.ascii.whitespace);
    return if (family.len == 0) null else family;
}

fn isGenericFontFamily(family: []const u8) bool {
    const generic_families = [_][]const u8{
        "serif",
        "sans-serif",
        "monospace",
        "cursive",
        "fantasy",
        "system-ui",
        "emoji",
        "math",
        "fangsong",
        "ui-serif",
        "ui-sans-serif",
        "ui-monospace",
        "ui-rounded",
    };
    for (generic_families) |generic_family| {
        if (std.ascii.eqlIgnoreCase(family, generic_family)) {
            return true;
        }
    }
    return false;
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
};

test "parseRequestedFamily handles quoted family names" {
    try std.testing.expectEqualStrings("Runner Font", parseRequestedFamily("16px \"Runner Font\"").?);
    try std.testing.expectEqualStrings("Runner Font", parseRequestedFamily("italic bold 16px 'Runner Font'").?);
}

test "parseRequestedFamily handles unquoted generic family names" {
    try std.testing.expectEqualStrings("sans-serif", parseRequestedFamily("16px sans-serif").?);
    try std.testing.expectEqualStrings("monospace", parseRequestedFamily("italic 16px monospace, serif").?);
}

test "isGenericFontFamily recognizes generic families" {
    try std.testing.expect(isGenericFontFamily("sans-serif"));
    try std.testing.expect(isGenericFontFamily("SYSTEM-UI"));
    try std.testing.expect(!isGenericFontFamily("Runner Font"));
}

const testing = @import("../../../testing.zig");
test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}

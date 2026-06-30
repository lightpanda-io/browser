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

// Parsed <script type="importmap"> content. Stored on the frame's
// ScriptManager and used by `resolveSpecifier` to map module specifiers
// to URLs per https://html.spec.whatwg.org/multipage/webappapis.html#import-maps

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("URL.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const SpecifierMap = std.json.ArrayHashMap(?[]const u8);

const ImportMap = @This();

/// Sorted by specifier length descending so the longest match wins.
imports: []const Entry = &.{},

/// Sorted by prefix length descending.
scopes: []const Scope = &.{},

const Entry = struct {
    specifier: []const u8,
    resolved: ?[:0]const u8,
};

const Scope = struct {
    prefix: []const u8,
    imports: []const Entry,
};

pub const empty: ImportMap = .{};

/// Parse `json_content` and merge it into `self`. Multiple <script type="importmap">
/// elements on a page combine with first-wins semantics: any specifier already
/// defined in `self` keeps its existing resolution, and existing scopes absorb
/// only the new keys from a same-prefix incoming scope.
pub fn merge(self: *ImportMap, arena: Allocator, base: [:0]const u8, json_content: []const u8) !void {
    const incoming = try parse(arena, base, json_content);
    self.imports = try mergeEntries(arena, self.imports, incoming.imports);
    self.scopes = try mergeScopes(arena, self.scopes, incoming.scopes);
}

fn mergeEntries(arena: Allocator, existing: []const Entry, incoming: []const Entry) ![]const Entry {
    if (incoming.len == 0) {
        return existing;
    }

    var list: std.ArrayList(Entry) = try .initCapacity(arena, existing.len + incoming.len);
    list.appendSliceAssumeCapacity(existing);
    for (incoming) |new_entry| {
        if (findEntry(existing, new_entry.specifier) != null) {
            continue;
        }
        list.appendAssumeCapacity(new_entry);
    }

    std.sort.pdq(Entry, list.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.specifier.len > b.specifier.len;
        }
    }.lessThan);
    return list.items;
}

fn findEntry(entries: []const Entry, specifier: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.specifier, specifier)) return i;
    }
    return null;
}

fn mergeScopes(arena: Allocator, existing: []const Scope, incoming: []const Scope) ![]const Scope {
    if (incoming.len == 0) {
        return existing;
    }
    var list: std.ArrayList(Scope) = try .initCapacity(arena, existing.len + incoming.len);

    // Existing scopes: if the incoming map has the same prefix, merge the
    // inner imports (existing entries win); otherwise carry through unchanged.
    for (existing) |ex| {
        if (findScope(incoming, ex.prefix)) |inc| {
            list.appendAssumeCapacity(.{
                .prefix = ex.prefix,
                .imports = try mergeEntries(arena, ex.imports, inc.imports),
            });
        } else {
            list.appendAssumeCapacity(ex);
        }
    }

    // Incoming scopes with prefixes the existing map didn't have.
    for (incoming) |inc| {
        if (findScope(existing, inc.prefix) == null) {
            list.appendAssumeCapacity(inc);
        }
    }

    std.sort.pdq(Scope, list.items, {}, struct {
        fn lessThan(_: void, a: Scope, b: Scope) bool {
            return a.prefix.len > b.prefix.len;
        }
    }.lessThan);
    return list.items;
}

fn findScope(scopes: []const Scope, prefix: []const u8) ?Scope {
    for (scopes) |s| {
        if (std.mem.eql(u8, s.prefix, prefix)) {
            return s;
        }
    }
    return null;
}

fn parse(arena: Allocator, base: [:0]const u8, json_content: []const u8) !ImportMap {
    const parsed = std.json.parseFromSliceLeaky(struct {
        imports: ?SpecifierMap = null,
        scopes: ?std.json.ArrayHashMap(SpecifierMap) = null,
    }, arena, json_content, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn(.js, "importmap json parse", .{ .err = err });
        return error.InvalidImportMap;
    };

    var im: ImportMap = .{};
    if (parsed.imports) |obj| {
        im.imports = try sortedNormalizedSpecifierMap(arena, base, obj);
    }
    if (parsed.scopes) |obj| {
        im.scopes = try sortedNormalizedScopes(arena, base, obj);
    }
    return im;
}

fn sortedNormalizedSpecifierMap(arena: Allocator, base: [:0]const u8, obj: SpecifierMap) ![]const Entry {
    const map = obj.map; // the JSON object is a thin wrapper over an ArrayHashMap

    var list: std.ArrayList(Entry) = try .initCapacity(arena, map.count());

    var it = map.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const normalized_key = (try normalizeSpecifierKey(arena, base, key)) orelse continue;

        // we specifically track null so that, on match, we return an error
        // rather than falling back to the next possible match.
        const resolved: ?[:0]const u8 = blk: {
            const url = kv.value_ptr.* orelse break :blk null;
            const resolved_url = parseIfLikeURL(arena, base, url) orelse {
                log.warn(.js, "importmap bad address", .{ .specifier = key, .address = url });
                break :blk null;
            };

            // Spec: if the key ends with "/" the address must end with "/" too.
            if (endsWithSlash(normalized_key) and !endsWithSlash(resolved_url)) {
                log.warn(.js, "importmap slash mismatch", .{ .specifier = key, .address = url });
                break :blk null;
            }
            break :blk resolved_url;
        };

        list.appendAssumeCapacity(.{ .specifier = normalized_key, .resolved = resolved });
    }
    std.sort.pdq(Entry, list.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.specifier.len > b.specifier.len;
        }
    }.lessThan);

    return list.items;
}

fn sortedNormalizedScopes(arena: Allocator, base: [:0]const u8, obj: std.json.ArrayHashMap(SpecifierMap)) ![]const Scope {
    const map = obj.map; // the JSON object is a thin wrapper over an ArrayHashMap

    var list: std.ArrayList(Scope) = try .initCapacity(arena, map.count());

    var it = map.iterator();
    while (it.next()) |kv| {
        const scope_key = kv.key_ptr.*;
        // Scope keys parse as ordinary URLs (relative against base), not as
        // URL-like specifiers — bare strings without ./, ../, /, or a scheme
        // are still allowed if they resolve against the base.
        const prefix = parseScopeKey(arena, base, scope_key) catch |err| {
            log.warn(.js, "importmap bad scope key", .{ .scope = scope_key, .err = err });
            continue;
        };

        list.appendAssumeCapacity(.{
            .prefix = prefix,
            .imports = try sortedNormalizedSpecifierMap(arena, base, kv.value_ptr.*),
        });
    }
    std.sort.pdq(Scope, list.items, {}, struct {
        fn lessThan(_: void, a: Scope, b: Scope) bool {
            return a.prefix.len > b.prefix.len;
        }
    }.lessThan);

    return list.items;
}

fn normalizeSpecifierKey(arena: Allocator, base: [:0]const u8, key: []const u8) !?[]const u8 {
    if (key.len == 0) {
        return null;
    }

    if (parseIfLikeURL(arena, base, key)) |url| {
        return url;
    }

    return try arena.dupe(u8, key);
}

fn parseScopeKey(arena: Allocator, base: [:0]const u8, key: []const u8) ![]const u8 {
    if (key.len == 0) {
        return base;
    }
    return URL.resolve(arena, base, key, .{ .encoding = "UTF-8" });
}

/// Returns the parsed URL if `specifier` looks like a URL. Else returns null;
fn parseIfLikeURL(arena: Allocator, base: [:0]const u8, specifier: []const u8) ?[:0]const u8 {
    if (specifier.len == 0) {
        return null;
    }

    if (specifier[0] == '/' or
        std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../") or
        hasScheme(specifier))
    {
        return URL.resolve(arena, base, specifier, .{ .encoding = "UTF-8" }) catch return null;
    }
    return null;
}

fn hasScheme(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..]) |c| {
        if (c == ':') return true;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

fn endsWithSlash(s: []const u8) bool {
    return s.len > 0 and s[s.len - 1] == '/';
}

/// Returns the resolved URL on success. Returns `null` when the specifier is
/// bare and no entry matches — the caller decides whether that's an error.
pub fn resolve(
    self: *const ImportMap,
    arena: Allocator,
    base: [:0]const u8,
    specifier: [:0]const u8,
) !?[:0]const u8 {
    const as_url = parseIfLikeURL(arena, base, specifier);

    const normalized: []const u8 = if (as_url) |u| u else specifier;

    for (self.scopes) |scope| {
        if (scopeMatches(scope.prefix, base) == false) {
            continue;
        }

        if (try resolveImportsMatch(arena, normalized, as_url, scope.imports)) |r| {
            return r;
        }
    }

    if (try resolveImportsMatch(arena, normalized, as_url, self.imports)) |r| {
        return r;
    }

    return as_url;
}

fn scopeMatches(prefix: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, prefix, base)) {
        return true;
    }
    return endsWithSlash(prefix) and std.mem.startsWith(u8, base, prefix);
}

fn resolveImportsMatch(
    arena: Allocator,
    normalized: []const u8,
    as_url: ?[:0]const u8,
    imports: []const Entry,
) !?[:0]const u8 {
    for (imports) |entry| {
        if (std.mem.eql(u8, entry.specifier, normalized)) {
            return entry.resolved orelse return error.SpecifierResolutionFailed;
        }

        if (endsWithSlash(entry.specifier) == false) {
            continue;
        }
        if (!std.mem.startsWith(u8, normalized, entry.specifier)) {
            continue;
        }

        // Per spec, trailing-slash prefix matching only applies when the
        // specifier is bare or its scheme is "special" (http(s), ws(s),
        // file, ftp). data:/blob:/about: don't match prefixes.
        if (as_url) |u| {
            if (isSpecialUrl(u) == false) {
                continue;
            }
        }

        const base_addr = entry.resolved orelse return error.SpecifierResolutionFailed;
        const after = normalized[entry.specifier.len..];
        const url = URL.resolve(arena, base_addr, after, .{ .encoding = "UTF-8" }) catch {
            return error.SpecifierResolutionFailed;
        };

        // Backtracking prevention — the resolved URL must remain under the
        // address (`../` etc. is not allowed to escape).
        if (!std.mem.startsWith(u8, url, base_addr)) {
            return error.SpecifierResolutionFailed;
        }

        return url;
    }

    return null;
}

fn isSpecialUrl(url: []const u8) bool {
    const colon = std.mem.indexOfScalarPos(u8, url, 0, ':') orelse return false;
    const scheme = url[0..colon];
    inline for (.{ "https", "http", "ws", "wss", "file", "ftp" }) |s| {
        if (std.ascii.eqlIgnoreCase(scheme, s)) {
            return true;
        }
    }
    return false;
}

const testing = @import("../testing.zig");
test "ImportMap: exact match" {
    defer testing.reset();

    const im = try testParse(
        \\{ "imports": { "moment": "/node_modules/moment/index.js" } }
    , "https://example.com/app/index.html");

    const r = try testResolve(&im, "https://example.com/app.mjs", "moment");
    try testing.expectString("https://example.com/node_modules/moment/index.js", r.?);
}

test "ImportMap: trailing slash prefix match" {
    defer testing.reset();

    const im = try testParse(
        \\{ "imports": { "moment/": "/node_modules/moment/src/" } }
    , "https://example.com/app/index.html");

    const r = try testResolve(&im, "https://example.com/app.mjs", "moment/foo");
    try testing.expectString("https://example.com/node_modules/moment/src/foo", r.?);
}

test "ImportMap: specificity — longest match wins" {
    defer testing.reset();

    const im = try testParse(
        \\{ "imports": {
        \\  "a": "/1",
        \\  "a/": "/2/",
        \\  "a/b": "/3",
        \\  "a/b/": "/4/"
        \\} }
    , "https://example.com/app/index.html");

    const r1 = try testResolve(&im, "https://example.com/app.mjs", "a");
    try testing.expectString("https://example.com/1", r1.?);

    const r2 = try testResolve(&im, "https://example.com/app.mjs", "a/");
    try testing.expectString("https://example.com/2/", r2.?);

    const r3 = try testResolve(&im, "https://example.com/app.mjs", "a/x");
    try testing.expectString("https://example.com/2/x", r3.?);

    const r4 = try testResolve(&im, "https://example.com/app.mjs", "a/b");
    try testing.expectString("https://example.com/3", r4.?);

    const r5 = try testResolve(&im, "https://example.com/app.mjs", "a/b/");
    try testing.expectString("https://example.com/4/", r5.?);

    const r6 = try testResolve(&im, "https://example.com/app.mjs", "a/b/c");
    try testing.expectString("https://example.com/4/c", r6.?);
}

test "ImportMap: scopes — most specific scope wins" {
    defer testing.reset();

    const im = try testParse(
        \\{
        \\  "imports": { "a": "/a-1.mjs", "b": "/b-1.mjs", "d": "/d-1.mjs" },
        \\  "scopes": {
        \\    "/scope2/": { "a": "/a-2.mjs", "d": "/d-2.mjs" },
        \\    "/scope2/scope3/": { "b": "/b-3.mjs", "d": "/d-3.mjs" }
        \\  }
        \\}
    , "https://example.com/app/index.html");

    // From scope2/scope3 base
    const a = try testResolve(&im, "https://example.com/scope2/scope3/foo.mjs", "a");
    try testing.expectString("https://example.com/a-2.mjs", a.?);

    const b = try testResolve(&im, "https://example.com/scope2/scope3/foo.mjs", "b");
    try testing.expectString("https://example.com/b-3.mjs", b.?);

    const d = try testResolve(&im, "https://example.com/scope2/scope3/foo.mjs", "d");
    try testing.expectString("https://example.com/d-3.mjs", d.?);

    // Falls back to scope2 for things not in scope3
    const a2 = try testResolve(&im, "https://example.com/scope2/foo.mjs", "a");
    try testing.expectString("https://example.com/a-2.mjs", a2.?);

    const b2 = try testResolve(&im, "https://example.com/scope2/foo.mjs", "b");
    try testing.expectString("https://example.com/b-1.mjs", b2.?);
}

test "ImportMap: bare specifier with no match returns null" {
    defer testing.reset();

    const im = try testParse(
        \\{ "imports": { "moment": "/m.js" } }
    , "https://example.com/app/index.html");

    const r = try testResolve(&im, "https://example.com/app.mjs", "nope");
    try testing.expectEqual(null, r);
}

test "ImportMap: URL-like specifier falls back to itself" {
    defer testing.reset();

    const im: ImportMap = .empty;

    const r = try testResolve(&im, "https://example.com/app.mjs", "./foo.js");
    try testing.expectString("https://example.com/foo.js", r.?);
}

test "ImportMap: null entry throws (no fallback)" {
    defer testing.reset();

    const im = try testParse(
        \\{ "imports": { "blocked": null } }
    , "https://example.com/app/index.html");

    try testing.expectError(error.SpecifierResolutionFailed, testResolve(&im, "https://example.com/app.mjs", "blocked"));
}

test "ImportMap: backtracking out of prefix throws" {
    defer testing.reset();

    const im = try testParse(
        \\{ "imports": { "moment/": "/node_modules/moment/src/" } }
    , "https://example.com/app/index.html");

    try testing.expectError(error.SpecifierResolutionFailed, testResolve(&im, "https://example.com/app.mjs", "moment/../backtrack"));
}

test "ImportMap: merge — first-wins on imports, new keys added" {
    defer testing.reset();
    const base: [:0]const u8 = "https://example.com/app/index.html";

    var im = try testParse(
        \\{ "imports": { "a": "/a-first.mjs", "b": "/b-first.mjs" } }
    , base);

    try im.merge(testing.arena_allocator, base,
        \\{ "imports": { "a": "/a-second.mjs", "c": "/c-second.mjs" } }
    );

    // First-wins: "a" keeps the original mapping.
    const a = try testResolve(&im, "https://example.com/app.mjs", "a");
    try testing.expectString("https://example.com/a-first.mjs", a.?);
    // New key from the second map shows up.
    const c = try testResolve(&im, "https://example.com/app.mjs", "c");
    try testing.expectString("https://example.com/c-second.mjs", c.?);
}

test "ImportMap: merge — same-prefix scopes merge their imports" {
    defer testing.reset();
    const base: [:0]const u8 = "https://example.com/app/index.html";

    var im = try testParse(
        \\{ "scopes": { "/s/": { "a": "/a-first.mjs" } } }
    , base);

    try im.merge(testing.arena_allocator, base,
        \\{ "scopes": { "/s/": { "a": "/a-second.mjs", "b": "/b-second.mjs" }, "/t/": { "x": "/x.mjs" } } }
    );

    // "a" within /s/ keeps its original value.
    const a = try testResolve(&im, "https://example.com/s/foo.mjs", "a");
    try testing.expectString("https://example.com/a-first.mjs", a.?);
    // "b" was added to /s/ from the second map.
    const b = try testResolve(&im, "https://example.com/s/foo.mjs", "b");
    try testing.expectString("https://example.com/b-second.mjs", b.?);
    // New scope /t/ landed too.
    const x = try testResolve(&im, "https://example.com/t/foo.mjs", "x");
    try testing.expectString("https://example.com/x.mjs", x.?);
}

fn testParse(content: []const u8, base: [:0]const u8) !ImportMap {
    return parse(testing.arena_allocator, base, content);
}

fn testResolve(im: *const ImportMap, base: [:0]const u8, specifier: [:0]const u8) !?[:0]const u8 {
    return im.resolve(testing.arena_allocator, base, specifier);
}

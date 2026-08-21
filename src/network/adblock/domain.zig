// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const public_suffix_list = @import("../../data/public_suffix_list.zig");

const Allocator = std.mem.Allocator;

/// One `$domain=` entry. `entity` marks the "google.*" form, whose `name` is
/// the hostname with its public suffix removed.
pub const Entry = struct {
    name: []const u8,
    entity: bool = false,
};

/// A parsed `$domain=` value. Both lists empty means the filter is
/// unconstrained; `included` empty with `excluded` set means "everywhere but".
pub const List = struct {
    included: []const Entry = &.{},
    excluded: []const Entry = &.{},

    pub const none: List = .{};

    pub fn isEmpty(self: List) bool {
        return self.included.len == 0 and self.excluded.len == 0;
    }

    /// uBO semantics.
    pub fn matches(self: List, hostname: []const u8) bool {
        if (self.isEmpty()) return true;
        // Only computed if an entity entry asks for it.
        const ent = if (hasEntity(self.excluded) or hasEntity(self.included))
            entity(hostname)
        else
            "";

        for (self.excluded) |e| {
            if (matchEntry(e, hostname, ent)) return false;
        }
        if (self.included.len == 0) return true;
        for (self.included) |e| {
            if (matchEntry(e, hostname, ent)) return true;
        }
        return false;
    }
};

fn hasEntity(entries: []const Entry) bool {
    for (entries) |e| {
        if (e.entity) return true;
    }
    return false;
}

fn matchEntry(e: Entry, hostname: []const u8, ent: []const u8) bool {
    if (e.entity) return std.mem.eql(u8, e.name, ent);
    return isSubdomainOf(hostname, e.name);
}

/// Whether `hostname` is `suffix` or one of its subdomains.
pub fn isSubdomainOf(hostname: []const u8, suffix: []const u8) bool {
    if (hostname.len == suffix.len) return std.mem.eql(u8, hostname, suffix);
    if (hostname.len < suffix.len + 1) return false;
    const at = hostname.len - suffix.len;
    return hostname[at - 1] == '.' and std.mem.eql(u8, hostname[at..], suffix);
}

/// Parses a `$domain=` value into its inclusions and exclusions. Entries
/// alias `raw`; only the two slices come from `arena`.
pub fn parse(
    arena: Allocator,
    raw: []const u8,
) error{ InvalidDomainList, NoSupportedDomains, OutOfMemory }!List {
    var included: std.ArrayList(Entry) = .empty;
    var excluded: std.ArrayList(Entry) = .empty;
    var had_entries = false;
    var any_supported = false;

    var it = std.mem.splitScalar(u8, raw, '|');
    while (it.next()) |raw_entry| {
        var entry = std.mem.trim(u8, raw_entry, &std.ascii.whitespace);
        if (entry.len == 0) continue;
        had_entries = true;

        var negated = false;
        if (entry[0] == '~') {
            negated = true;
            entry = entry[1..];
            if (entry.len == 0) return error.InvalidDomainList;
        }

        // /regex/ entries are valid uBO syntax but unsupported here.
        if (entry[0] == '/') continue;

        // An entity ("google.*") is the hostname without its public suffix.
        var is_entity = false;
        if (std.mem.endsWith(u8, entry, ".*")) {
            is_entity = true;
            entry = entry[0 .. entry.len - 2];
            if (entry.len == 0) return error.InvalidDomainList;
        }

        if (!isValidHost(entry)) return error.InvalidDomainList;
        any_supported = true;

        const name = try lowered(arena, entry);
        const list = if (negated) &excluded else &included;
        try list.append(arena, .{ .name = name, .entity = is_entity });
    }

    if (had_entries and !any_supported) {
        // Every entry was an unsupported /regex/; the caller must drop the
        // rule rather than let it apply everywhere.
        return error.NoSupportedDomains;
    }

    return .{
        .included = included.items,
        .excluded = excluded.items,
    };
}

pub fn registrable(host: []const u8) []const u8 {
    if (isIpLiteral(host)) return host;
    var i = std.mem.lastIndexOfScalar(u8, host, '.') orelse return host;
    while (true) {
        i = std.mem.lastIndexOfScalar(u8, host[0..i], '.') orelse return host;
        const start = i + 1;
        if (public_suffix_list.lookup(host[start..]) == false) {
            return host[start..];
        }
    }
}

pub fn entity(host: []const u8) []const u8 {
    if (isIpLiteral(host)) return "";
    const reg = registrable(host);
    const dot = std.mem.indexOfScalar(u8, reg, '.') orelse return "";
    return reg[0..dot];
}

/// Whether two hostnames belong to different sites.
pub fn isThirdParty(request_host: []const u8, source_host: []const u8) bool {
    if (std.mem.eql(u8, request_host, source_host)) return false;
    return !std.mem.eql(u8, registrable(request_host), registrable(source_host));
}

fn isIpLiteral(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '[') return true; // IPv6, already bracketed by the URL parser
    for (host) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return false;
    }
    return true;
}

fn isValidHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '.' or host[host.len - 1] == '.') return false;
    var prev: u8 = '.';
    for (host) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
        if (c == '.' and prev == '.') return false;
        prev = c;
    }
    return true;
}

/// Returns the input slice unchanged when it is already lowercase, otherwise
/// an arena-allocated lowercase copy.
pub fn lowered(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    for (s, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            const out = try arena.dupe(u8, s);
            for (out[i..], i..) |c2, j| out[j] = std.ascii.toLower(c2);
            return out;
        }
    }
    return s;
}

const testing = @import("../../testing.zig");

test "adblock.domain: plain, negated and entity entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = try parse(arena, "example.com|~sub.Example.com|google.*");
    try testing.expectEqual(2, list.included.len);
    try testing.expectString("example.com", list.included[0].name);
    try testing.expect(!list.included[0].entity);
    try testing.expectString("google", list.included[1].name);
    try testing.expect(list.included[1].entity);

    try testing.expectEqual(1, list.excluded.len);
    try testing.expectString("sub.example.com", list.excluded[0].name);
}

test "adblock.domain: matching against a source hostname" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An entry matches itself and its subdomains.
    var list = try parse(arena, "example.com");
    try testing.expect(list.matches("example.com"));
    try testing.expect(list.matches("www.example.com"));
    try testing.expect(!list.matches("notexample.com"));
    try testing.expect(!list.matches("example.org"));

    // An exclusion wins over the inclusion that covers it.
    list = try parse(arena, "example.com|~ads.example.com");
    try testing.expect(list.matches("www.example.com"));
    try testing.expect(!list.matches("ads.example.com"));
    try testing.expect(!list.matches("x.ads.example.com"));

    // Exclusions alone mean "everywhere but".
    list = try parse(arena, "~example.com");
    try testing.expect(list.matches("other.com"));
    try testing.expect(!list.matches("example.com"));

    // An entity ignores the public suffix.
    list = try parse(arena, "google.*");
    try testing.expect(list.matches("google.com"));
    try testing.expect(list.matches("www.google.com"));
    try testing.expect(!list.matches("google.example.com"));

    // No list at all constrains nothing.
    try testing.expect(List.none.matches("anything.com"));
}

test "adblock.domain: regex entries are skipped, all-regex errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = try parse(arena, "/foo/|example.com");
    try testing.expectEqual(1, list.included.len);
    try testing.expectError(error.NoSupportedDomains, parse(arena, "/foo/"));
}

test "adblock.domain: invalid entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.InvalidDomainList, parse(arena, "exa mple.com"));
    try testing.expectError(error.InvalidDomainList, parse(arena, ".example.com"));
    try testing.expectError(error.InvalidDomainList, parse(arena, "~"));
}

// The public suffix list is stubbed to {gov.uk, api.gov.uk} in test builds,
// so these use .com and gov.uk only.
test "adblock.domain: registrable domain and entity" {
    try testing.expectString("example.com", registrable("example.com"));
    try testing.expectString("example.com", registrable("a.b.example.com"));
    try testing.expectString("dept.gov.uk", registrable("www.dept.gov.uk"));
    // No registrable domain to find: single labels and IP literals.
    try testing.expectString("localhost", registrable("localhost"));
    try testing.expectString("127.0.0.1", registrable("127.0.0.1"));
    try testing.expectString("[::1]", registrable("[::1]"));

    try testing.expectString("example", entity("a.example.com"));
    try testing.expectString("dept", entity("www.dept.gov.uk"));
    try testing.expectString("", entity("127.0.0.1"));
}

test "adblock.domain: third party" {
    try testing.expect(!isThirdParty("example.com", "example.com"));
    try testing.expect(!isThirdParty("cdn.example.com", "www.example.com"));
    try testing.expect(isThirdParty("ads.com", "example.com"));
    // Sharing a public suffix is not sharing a site.
    try testing.expect(isThirdParty("a.gov.uk", "b.gov.uk"));
}

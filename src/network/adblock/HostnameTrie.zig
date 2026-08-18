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

//! A container of hostname tries: a port of uBlock Origin's
//! HNTrieContainer (src/js/hntrie.js), a character-level radix trie
//! specialized for hostname matching.
//!
//! A stored hostname matches itself and any of its subdomains, so the trie
//! compares suffixes: both the needle and the stored segments are consumed
//! back-to-front, and segment bytes are stored reversed so the matcher
//! reads `chars` forward while walking the needle backwards. A match only
//! counts on a label boundary — the needle must be fully consumed or the
//! next byte toward its start must be a '.' ("abc.com" matches
//! "www.abc.com" but not "xabc.com").
//!
//! Character-level segments keep every sibling chain shorter than the
//! hostname alphabet (~38), so linear scans stay cheap no matter how many
//! hostnames are stored. Cells live in one flat array and link through
//! indices, which keeps the structure position-independent: growth cannot
//! invalidate links and serialization is a plain byte copy.
//!
//! Why a trie and not a hash map of hostnames? A hash map only answers
//! exact-match queries, so subdomain matching means hashing and looking up
//! every suffix of the needle in turn ("a.b.ads.example.com" costs five
//! probes, each over a different slice); the trie consumes the needle once,
//! byte by byte, and reports the match offset as a side effect of the walk.
//!
//! It also uses less memory. A hash map stores every hostname in full, plus
//! a slice header (and any hash metadata) per key, plus the empty slots the
//! load factor demands. Here entries share their common suffix: the bytes of
//! ".com" or ".google.com" are written once and reused by everything ending
//! in them, `chars` is bump-allocated with no per-entry header, a cell is 12
//! bytes, and both arrays are packed with no slack. On top of that, `add`
//! drops any hostname already covered by a shorter stored suffix.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");

const HostnameTrie = @This();

/// Cell 0 is reserved as the null sentinel, link value 0 means "none".
cells: std.ArrayList(Cell),
/// Bytes are stored reversed; bump-allocated, never freed
/// individually. Split segments alias sub-ranges of existing bytes.
chars: std.ArrayList(u8),

/// Segments hold at most 127 bytes (V.len is 7 bits); longer remainders
/// chain through `right`.
const SEG_MAX = std.math.maxInt(u7);

const Cell = extern struct {
    /// Next sibling: an alternative segment at this depth.
    down: u32,
    /// Child: the continuation once this segment matched.
    right: u32,
    v: V,
};

/// uBO's packed segment descriptor: `offset << 8 | boundary | len`.
const V = packed struct(u32) {
    /// Number of segment bytes, 1..SEG_MAX.
    len: u7,
    /// A stored hostname ends at this segment's end.
    boundary: bool,
    /// Start of the segment's bytes in `chars`.
    offset: u24,
};

comptime {
    if (@sizeOf(Cell) != 12) unreachable;
}

pub const Error = error{
    OutOfMemory,
    InvalidHostname,
    TrieFull,
};

pub fn init(allocator: Allocator) Allocator.Error!HostnameTrie {
    // TODO: We can mmap memory used here together with memory that's used for
    // easylist parsing.
    var self: HostnameTrie = .{
        .cells = .empty,
        .chars = .empty,
    };
    errdefer self.deinit(allocator);
    try self.cells.append(allocator, .{ .down = 0, .right = 0, .v = @bitCast(@as(u32, 0)) });
    return self;
}

pub fn deinit(self: *HostnameTrie, allocator: Allocator) void {
    self.cells.deinit(allocator);
    self.chars.deinit(allocator);
}

/// Creates an empty trie and returns its handle.
/// Distinct tries share the container's cell and character storage.
pub fn createTrie(self: *HostnameTrie, allocator: Allocator) Allocator.Error!u32 {
    const root: u32 = @intCast(self.cells.items.len);
    try self.cells.append(allocator, .{ .down = 0, .right = 0, .v = @bitCast(@as(u32, 0)) });
    return root;
}

/// Expects a normalized hostname: lowercase, no trailing dot.
pub fn add(self: *HostnameTrie, allocator: Allocator, root: u32, hostname: []const u8) Error!void {
    if (hostname.len == 0) return error.InvalidHostname;
    // Index just past the next needle byte to consume.
    var lhnchar = hostname.len;

    if (self.cells.items[root].down == 0) {
        const leaf = try self.addLeafCell(allocator, hostname, lhnchar);
        self.cells.items[root].down = leaf;
        return;
    }

    var icell = self.cells.items[root].down;
    while (true) {
        const v = self.cells.items[icell].v;
        // First byte mismatch; move to the next sibling, or become one.
        if (self.chars.items[v.offset] != hostname[lhnchar - 1]) {
            if (self.cells.items[icell].down == 0) {
                const leaf = try self.addLeafCell(allocator, hostname, lhnchar);
                self.cells.items[icell].down = leaf;
                return;
            }
            icell = self.cells.items[icell].down;
            continue;
        }
        // First byte matched; find the first mismatch in the rest.
        var isegchar: usize = 1;
        lhnchar -= 1;
        const lsegchar: usize = v.len;
        while (isegchar != lsegchar and lhnchar != 0 and
            self.chars.items[v.offset + isegchar] == hostname[lhnchar - 1])
        {
            isegchar += 1;
            lhnchar -= 1;
        }
        if (isegchar == lsegchar) {
            // Whole segment matched.
            if (lhnchar == 0) {
                // Duplicate entries just (re)mark the boundary.
                self.cells.items[icell].v.boundary = true;
                return;
            }
            // The remainder sits on a label boundary of a stored entry:
            // it could only ever lose to that shorter suffix, drop it.
            if (v.boundary and hostname[lhnchar - 1] == '.') return;
            if (self.cells.items[icell].right == 0) {
                const leaf = try self.addLeafCell(allocator, hostname, lhnchar);
                self.cells.items[icell].right = leaf;
                return;
            }
            icell = self.cells.items[icell].right;
            continue;
        }
        // Partial match: split the segment at the mismatch. The tail cell
        // aliases the existing bytes and inherits the boundary and child.
        const cont = try self.addCell(allocator, .{
            .down = 0,
            .right = self.cells.items[icell].right,
            .v = .{
                .len = @intCast(lsegchar - isegchar),
                .boundary = v.boundary,
                .offset = v.offset + @as(u24, @intCast(isegchar)),
            },
        });
        self.cells.items[icell].right = cont;
        self.cells.items[icell].v = .{
            .len = @intCast(isegchar),
            .boundary = lhnchar == 0,
            .offset = v.offset,
        };
        if (lhnchar != 0) {
            const leaf = try self.addLeafCell(allocator, hostname, lhnchar);
            self.cells.items[cont].down = leaf;
        }
        return;
    }
}

pub fn matches(self: *const HostnameTrie, root: u32, hostname: []const u8) ?usize {
    const cells = self.cells.items;
    const chars = self.chars.items;
    var icell = cells[root].down;
    if (icell == 0) return null;
    var ineedle = hostname.len;
    while (true) {
        if (ineedle == 0) return null;
        ineedle -= 1;
        const c = hostname[ineedle];
        // Find a sibling whose segment starts with `c`.
        var v = cells[icell].v;
        while (chars[v.offset] != c) {
            icell = cells[icell].down;
            if (icell == 0) return null;
            v = cells[icell].v;
        }
        // Every remaining byte of the segment must match.
        if (v.len > 1) {
            const n: usize = v.len - 1;
            if (n > ineedle) return null;
            for (chars[v.offset + 1 ..][0..n]) |sc| {
                ineedle -= 1;
                if (sc != hostname[ineedle]) return null;
            }
        }
        if (v.boundary) {
            if (ineedle == 0 or hostname[ineedle - 1] == '.') return ineedle;
        }
        icell = cells[icell].right;
        if (icell == 0) return null;
    }
}

fn addCell(self: *HostnameTrie, allocator: Allocator, cell: Cell) Allocator.Error!u32 {
    const icell: u32 = @intCast(self.cells.items.len);
    try self.cells.append(allocator, cell);
    return icell;
}

fn addLeafCell(self: *HostnameTrie, allocator: Allocator, hostname: []const u8, lhnchar: usize) Error!u32 {
    var remaining = lhnchar;
    const first: u32 = @intCast(self.cells.items.len);
    while (remaining > SEG_MAX) {
        const v = try self.addSegment(allocator, hostname, remaining, remaining - SEG_MAX);
        const icell: u32 = @intCast(self.cells.items.len);
        try self.cells.append(allocator, .{ .down = 0, .right = icell + 1, .v = v });
        remaining -= SEG_MAX;
    }
    var v = try self.addSegment(allocator, hostname, remaining, 0);
    v.boundary = true;
    try self.cells.append(allocator, .{ .down = 0, .right = 0, .v = v });
    return first;
}

fn addSegment(self: *HostnameTrie, allocator: Allocator, hostname: []const u8, lsegchar: usize, lsegend: usize) Error!V {
    const len = lsegchar - lsegend;
    lp.assert(len >= 1 and len <= SEG_MAX, "HostnameTrie.addSegment: bad segment length", .{ .len = len });
    const offset = self.chars.items.len;
    if (offset + len > std.math.maxInt(u24)) return error.TrieFull;
    try self.chars.ensureUnusedCapacity(allocator, len);
    var i = lsegchar;
    while (i != lsegend) {
        i -= 1;
        self.chars.appendAssumeCapacity(hostname[i]);
    }
    return .{ .len = @intCast(len), .boundary = false, .offset = @intCast(offset) };
}

const testing = @import("../../testing.zig");

test "adblock.HostnameTrie: exact and subdomain matching" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    try trie.add(testing.allocator, root, "google.com");
    try trie.add(testing.allocator, root, "doubleclick.net");

    try testing.expectEqual(0, trie.matches(root, "google.com").?);
    try testing.expectEqual(4, trie.matches(root, "www.google.com").?);

    const needle = "metrics.ssl.doubleclick.net";
    const offset = trie.matches(root, needle).?;
    try testing.expectString("doubleclick.net", needle[offset..]);

    try testing.expectEqual(null, trie.matches(root, "google.net"));
    try testing.expectEqual(null, trie.matches(root, "evilgoogle.com"));
    try testing.expectEqual(null, trie.matches(root, "gle.com"));
    try testing.expectEqual(null, trie.matches(root, "google.com.evil.org"));
    try testing.expectEqual(null, trie.matches(root, "com"));
    try testing.expectEqual(null, trie.matches(root, ""));
}

test "adblock.HostnameTrie: duplicate and covered entries store nothing" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    try trie.add(testing.allocator, root, "google.com");
    const cells_len = trie.cells.items.len;
    const chars_len = trie.chars.items.len;

    // An exact duplicate is a no-op.
    try trie.add(testing.allocator, root, "google.com");
    try testing.expectEqual(cells_len, trie.cells.items.len);
    try testing.expectEqual(chars_len, trie.chars.items.len);

    // A subdomain of a stored entry could never win over the shorter
    // suffix, so it is dropped before allocating anything.
    try trie.add(testing.allocator, root, "ads.google.com");
    try testing.expectEqual(cells_len, trie.cells.items.len);
    try testing.expectEqual(chars_len, trie.chars.items.len);

    // The reverse order: a later, shorter entry splits the stored segment
    // and lands its boundary on the split point.
    try trie.add(testing.allocator, root, "mail.example.org");
    try trie.add(testing.allocator, root, "example.org");
    // The shorter suffix now wins for its former subdomain entry.
    try testing.expectEqual(5, trie.matches(root, "mail.example.org").?);
    try testing.expectEqual(0, trie.matches(root, "example.org").?);
}

test "adblock.HostnameTrie: segment splitting" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    // Reversed, "google.com" and "gle.com" share the prefix "moc.elg":
    // adding the shorter one splits the segment mid-label.
    try trie.add(testing.allocator, root, "google.com");
    try trie.add(testing.allocator, root, "gle.com");
    try testing.expectEqual(0, trie.matches(root, "google.com").?);
    try testing.expectEqual(4, trie.matches(root, "www.google.com").?);
    try testing.expectEqual(0, trie.matches(root, "gle.com").?);
    try testing.expectEqual(2, trie.matches(root, "x.gle.com").?);
    // "oogle.com" reaches the "gle.com" boundary mid-hostname ('o' is not
    // a label boundary) and dies in the next segment.
    try testing.expectEqual(null, trie.matches(root, "oogle.com"));
    try testing.expectEqual(null, trie.matches(root, "e.com"));

    // A non-'.' continuation past a stored boundary is its own entry:
    // "xgoogle.com" is not a subdomain of "google.com".
    try trie.add(testing.allocator, root, "xgoogle.com");
    try testing.expectEqual(0, trie.matches(root, "xgoogle.com").?);
    try testing.expectEqual(2, trie.matches(root, "a.xgoogle.com").?);
    try testing.expectEqual(4, trie.matches(root, "sub.google.com").?);
}

test "adblock.HostnameTrie: sibling chains keep earlier entries intact" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    try trie.add(testing.allocator, root, "google.com");
    try trie.add(testing.allocator, root, "awesomes.com");

    try testing.expectEqual(0, trie.matches(root, "google.com").?);
    try testing.expectEqual(0, trie.matches(root, "awesomes.com").?);
    try testing.expectEqual(4, trie.matches(root, "sub.awesomes.com").?);
    try testing.expectEqual(null, trie.matches(root, "awesome.com"));
}

test "adblock.HostnameTrie: hostnames longer than one segment" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    // 191 bytes: the leaf spans two chained segments (127 + 64).
    const long = "a" ** 63 ++ "." ++ "b" ** 63 ++ "." ++ "c" ** 63;
    try trie.add(testing.allocator, root, long);
    const cells_len = trie.cells.items.len;
    try trie.add(testing.allocator, root, long); // duplicate multi-segment entry: no-op
    try testing.expectEqual(cells_len, trie.cells.items.len);
    try testing.expectEqual(0, trie.matches(root, long).?);
    try testing.expectEqual(2, trie.matches(root, "x." ++ long).?);
    // A suffix of the stored hostname is not an entry.
    try testing.expectEqual(null, trie.matches(root, "b" ** 63 ++ "." ++ "c" ** 63));
}

test "adblock.HostnameTrie: stored deeper than query" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    try trie.add(testing.allocator, root, "ads.tracking.example.com");
    try testing.expectEqual(null, trie.matches(root, "example.com"));
    try testing.expectEqual(null, trie.matches(root, "tracking.example.com"));
    try testing.expectEqual(0, trie.matches(root, "ads.tracking.example.com").?);
    try testing.expectEqual(2, trie.matches(root, "x.ads.tracking.example.com").?);
}

test "adblock.HostnameTrie: multiple tries share one container" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const blocked = try trie.createTrie(testing.allocator);
    const allowed = try trie.createTrie(testing.allocator);

    try trie.add(testing.allocator, blocked, "ads.example.com");
    try trie.add(testing.allocator, allowed, "cdn.example.com");

    try testing.expectEqual(0, trie.matches(blocked, "ads.example.com").?);
    try testing.expectEqual(null, trie.matches(blocked, "cdn.example.com"));
    try testing.expectEqual(0, trie.matches(allowed, "cdn.example.com").?);
    try testing.expectEqual(null, trie.matches(allowed, "ads.example.com"));
}

test "adblock.HostnameTrie: degenerate inputs" {
    var trie: HostnameTrie = try .init(testing.allocator);
    defer trie.deinit(testing.allocator);
    const root = try trie.createTrie(testing.allocator);

    try testing.expectError(error.InvalidHostname, trie.add(testing.allocator, root, ""));
    try testing.expectEqual(null, trie.matches(root, "example.com"));

    try trie.add(testing.allocator, root, "example.com");
    // Trailing dot: no stored segment starts with '.'.
    try testing.expectEqual(null, trie.matches(root, "example.com."));
    // Byte-faithful like uBO: the walk returns at the boundary before
    // ever seeing the malformed empty label.
    try testing.expectEqual(3, trie.matches(root, "a..example.com").?);
}

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
const posix = std.posix;
const libcurl = @import("../sys/libcurl.zig");

const IpFilter = @This();

/// Binary representation for bitwise CIDR comparison.
pub const Ipv4Addr = [4]u8;
pub const Ipv6Addr = [16]u8;

pub const CidrV4 = struct {
    network: u32,
    mask: u32,

    fn fromPrefix(addr: Ipv4Addr, prefix_len: u6) CidrV4 {
        const network = std.mem.readInt(u32, &addr, .big);
        const mask: u32 = if (prefix_len == 0)
            0
        else if (prefix_len == 32)
            0xFFFFFFFF
        else
            ~(@as(u32, 0xFFFFFFFF) >> @intCast(prefix_len));
        return .{ .network = network, .mask = mask };
    }
};

pub const CidrV6 = struct {
    network_hi: u64,
    network_lo: u64,
    mask_hi: u64,
    mask_lo: u64,

    fn fromPrefix(addr: Ipv6Addr, prefix_len: u8) CidrV6 {
        const network_hi = std.mem.readInt(u64, addr[0..8], .big);
        const network_lo = std.mem.readInt(u64, addr[8..16], .big);
        var mask_hi: u64 = 0;
        var mask_lo: u64 = 0;
        if (prefix_len > 0) {
            if (prefix_len < 64) {
                mask_hi = ~(@as(u64, 0xFFFFFFFFFFFFFFFF) >> @intCast(prefix_len));
            } else if (prefix_len == 64) {
                mask_hi = 0xFFFFFFFFFFFFFFFF;
            } else if (prefix_len < 128) {
                mask_hi = 0xFFFFFFFFFFFFFFFF;
                mask_lo = ~(@as(u64, 0xFFFFFFFFFFFFFFFF) >> @intCast(prefix_len - 64));
            } else {
                // prefix_len == 128
                mask_hi = 0xFFFFFFFFFFFFFFFF;
                mask_lo = 0xFFFFFFFFFFFFFFFF;
            }
        }
        return .{ .network_hi = network_hi, .network_lo = network_lo, .mask_hi = mask_hi, .mask_lo = mask_lo };
    }
};

// IpFilter fields
block_private: bool,
cidrs: ?Cidrs,

// ── Comptime helpers ─────────────────────────────────────────────────────────

/// Comptime helper: parse dotted-decimal IPv4 to [4]u8.
fn parseIpv4Comptime(comptime s: []const u8) Ipv4Addr {
    var result: Ipv4Addr = undefined;
    var octet: u8 = 0;
    var octet_idx: usize = 0;
    for (s) |ch| {
        if (ch == '.') {
            result[octet_idx] = octet;
            octet_idx += 1;
            octet = 0;
        } else {
            octet = octet * 10 + (ch - '0');
        }
    }
    result[octet_idx] = octet;
    return result;
}

/// Comptime helper: build a CidrV4.
fn makeCidrV4(comptime addr: []const u8, comptime prefix: u6) CidrV4 {
    return CidrV4.fromPrefix(parseIpv4Comptime(addr), prefix);
}

/// Comptime helper: build a CidrV6 from a 16-byte literal array.
fn makeCidrV6(comptime bytes: Ipv6Addr, comptime prefix: u8) CidrV6 {
    return CidrV6.fromPrefix(bytes, prefix);
}

// ── Comptime CIDR range tables ───────────────────────────────────────────────

const PRIVATE_V4 = [_]CidrV4{
    makeCidrV4("127.0.0.0", 8), // localhost
    makeCidrV4("0.0.0.0", 8), // current network
    makeCidrV4("10.0.0.0", 8), // RFC1918
    makeCidrV4("172.16.0.0", 12), // RFC1918
    makeCidrV4("192.168.0.0", 16), // RFC1918
    makeCidrV4("169.254.0.0", 16), // link-local
};

const PRIVATE_V6 = [_]CidrV6{
    // ::/128 — IPv6 Unspecified
    makeCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 128),
    // ::1/128 — IPv6 localhost
    makeCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 128),
    // fe80::/10 — link-local
    makeCidrV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 10),
    // fc00::/7 — ULA
    makeCidrV6(.{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 7),
};

// ── Runtime IP parsing ───────────────────────────────────────────────────────

/// Parse dotted-decimal IPv4 string to 4-byte array. Returns null on parse failure.
fn parseIpv4(str: []const u8) ?Ipv4Addr {
    var addr: Ipv4Addr = undefined;
    var it = std.mem.splitScalar(u8, str, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        addr[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return addr;
}

/// Parse IPv6 string to 16-byte array. Handles compressed notation.
/// Strips zone ID (e.g. "fe80::1%eth0" -> "fe80::1").
/// Returns null on parse failure.
fn parseIpv6(str: []const u8) ?Ipv6Addr {
    // Strip zone ID
    const clean = if (std.mem.indexOfScalar(u8, str, '%')) |idx| str[0..idx] else str;
    const parsed = std.net.Address.parseIp6(clean, 0) catch return null;
    return parsed.in6.sa.addr;
}

// ── CIDR matching ────────────────────────────────────────────────────────────

/// Detect IPv4-mapped IPv6 address (::ffff:x.x.x.x).
/// Returns the embedded IPv4 address if detected, null otherwise.
fn isIpv4Mapped(addr: Ipv6Addr) ?Ipv4Addr {
    // IPv4-mapped prefix: 10 zero bytes + 2 0xFF bytes
    const prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (!std.mem.eql(u8, addr[0..12], &prefix)) return null;
    return addr[12..16].*;
}

/// Check if IPv4 address falls within a CIDR range.
fn matchesCidrV4(addr: Ipv4Addr, cidr: CidrV4) bool {
    const addr_int = std.mem.readInt(u32, &addr, .big);
    return (addr_int ^ cidr.network) & cidr.mask == 0;
}

/// Check if IPv6 address falls within a CIDR range.
fn matchesCidrV6(addr: Ipv6Addr, cidr: CidrV6) bool {
    const addr_hi = std.mem.readInt(u64, addr[0..8], .big);
    const addr_lo = std.mem.readInt(u64, addr[8..16], .big);
    return ((addr_hi ^ cidr.network_hi) & cidr.mask_hi == 0) and
        ((addr_lo ^ cidr.network_lo) & cidr.mask_lo == 0);
}

// ── Public API ───────────────────────────────────────────────────────────────

pub const Cidrs = struct {
    v4: []CidrV4,
    v6: []CidrV6,
    allow_v4: []CidrV4,
    allow_v6: []CidrV6,

    pub fn deinit(self: Cidrs, allocator: std.mem.Allocator) void {
        allocator.free(self.v4);
        allocator.free(self.v6);
        allocator.free(self.allow_v4);
        allocator.free(self.allow_v6);
    }
};

/// Parse a comma-separated list of CIDR strings (e.g. "10.0.0.0/8,2001:db8::/32")
/// into a Cidrs struct. Entries prefixed with '-' are added to the allow list
/// (e.g. "-10.0.0.42/32" exempts that IP from blocking).
/// Caller owns the returned Cidrs and must free them via Cidrs.deinit.
/// Returns error.InvalidCidr on any malformed entry.
pub fn parseCidrList(
    allocator: std.mem.Allocator,
    cidr_str: []const u8,
) !Cidrs {
    var v4_list: std.ArrayList(CidrV4) = .empty;
    errdefer v4_list.deinit(allocator);
    var v6_list: std.ArrayList(CidrV6) = .empty;
    errdefer v6_list.deinit(allocator);
    var allow_v4_list: std.ArrayList(CidrV4) = .empty;
    errdefer allow_v4_list.deinit(allocator);
    var allow_v6_list: std.ArrayList(CidrV6) = .empty;
    errdefer allow_v6_list.deinit(allocator);

    var it = std.mem.splitScalar(u8, cidr_str, ',');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;

        const is_allow = trimmed[0] == '-';
        const cidr_part = if (is_allow) trimmed[1..] else trimmed;

        const slash = std.mem.indexOfScalar(u8, cidr_part, '/') orelse return error.InvalidCidr;
        const addr_str = cidr_part[0..slash];
        const prefix_str = cidr_part[slash + 1 ..];

        if (parseIpv4(addr_str)) |v4| {
            const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidCidr;
            if (prefix > 32) return error.InvalidCidr;
            const cidr = CidrV4.fromPrefix(v4, @intCast(prefix));
            if (is_allow) {
                try allow_v4_list.append(allocator, cidr);
            } else {
                try v4_list.append(allocator, cidr);
            }
        } else if (parseIpv6(addr_str)) |v6| {
            const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidCidr;
            if (prefix > 128) return error.InvalidCidr;
            const cidr = CidrV6.fromPrefix(v6, prefix);
            if (is_allow) {
                try allow_v6_list.append(allocator, cidr);
            } else {
                try v6_list.append(allocator, cidr);
            }
        } else {
            return error.InvalidCidr;
        }
    }

    const v4 = try v4_list.toOwnedSlice(allocator);
    errdefer allocator.free(v4);
    const v6 = try v6_list.toOwnedSlice(allocator);
    errdefer allocator.free(v6);
    const allow_v4 = try allow_v4_list.toOwnedSlice(allocator);
    errdefer allocator.free(allow_v4);
    const allow_v6 = try allow_v6_list.toOwnedSlice(allocator);
    return .{ .v4 = v4, .v6 = v6, .allow_v4 = allow_v4, .allow_v6 = allow_v6 };
}

// Create a IpFilter. Set block_private to block outbound requests to RFC1918,
// localhost, link-local, and ULA ranges. Pass parsed CIDRs for additional
// custom block/allow ranges; the filter takes ownership of the Cidrs and will
// free them on deinit.
pub fn init(
    block_private: bool,
    cidrs: ?Cidrs,
) IpFilter {
    return .{
        .block_private = block_private,
        .cidrs = cidrs,
    };
}

pub fn deinit(self: IpFilter, allocator: std.mem.Allocator) void {
    if (self.cidrs) |c| {
        c.deinit(allocator);
    }
}

fn isBlockedV4(self: *const IpFilter, addr: Ipv4Addr) bool {
    if (self.cidrs) |c| {
        for (c.allow_v4) |cidr| {
            if (matchesCidrV4(addr, cidr)) {
                return false;
            }
        }
        for (c.v4) |cidr| {
            if (matchesCidrV4(addr, cidr)) {
                return true;
            }
        }
    }

    if (self.block_private) {
        for (PRIVATE_V4) |cidr| {
            if (matchesCidrV4(addr, cidr)) {
                return true;
            }
        }
    }

    return false;
}

fn isBlockedV6(self: *const IpFilter, addr: Ipv6Addr) bool {
    if (self.cidrs) |c| {
        for (c.allow_v6) |cidr| {
            if (matchesCidrV6(addr, cidr)) {
                return false;
            }
        }
        for (c.v6) |cidr| {
            if (matchesCidrV6(addr, cidr)) {
                return true;
            }
        }
    }

    if (self.block_private) {
        for (PRIVATE_V6) |cidr| {
            if (matchesCidrV6(addr, cidr)) {
                return true;
            }
        }
    }
    return false;
}

/// Check if an address from curl's opensocket callback should be blocked.
/// Extracts the IP directly from the sockaddr structure; no string parsing needed.
/// Fail-closed: unknown address family -> true (blocked).
pub fn isBlockedSockaddr(self: *const IpFilter, sa: *const libcurl.CurlSockAddr) bool {
    switch (sa.family) {
        posix.AF.INET => {
            const sin: *const posix.sockaddr.in = @ptrCast(&sa.addr);
            // sin.addr is in network byte order (big-endian); convert to host bytes
            const bytes: [4]u8 = @bitCast(sin.addr);
            return self.isBlockedV4(bytes);
        },
        posix.AF.INET6 => {
            const sin6: *const posix.sockaddr.in6 = @ptrCast(&sa.addr);
            const addr: Ipv6Addr = sin6.addr;
            if (isIpv4Mapped(addr)) |v4| return self.isBlockedV4(v4);
            return self.isBlockedV6(addr);
        },
        else => return true, // unknown family -> fail-closed
    }
}

const testing = @import("../testing.zig");
test "IpFilter: IPv4 CIDR matching: private group boundaries" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.testBlocked("0.0.0.0"));

    // Loopback
    try testing.expect(filter.testBlocked("127.0.0.1"));
    try testing.expect(filter.testBlocked("127.255.255.255"));
    try testing.expect(!filter.testBlocked("128.0.0.1"));

    // RFC1918 10.0.0.0/8
    try testing.expect(filter.testBlocked("10.0.0.1"));
    try testing.expect(filter.testBlocked("10.255.255.255"));
    try testing.expect(!filter.testBlocked("11.0.0.0"));

    // RFC1918 172.16.0.0/12 — critical boundary
    try testing.expect(!filter.testBlocked("172.15.255.255")); // MUST NOT block
    try testing.expect(filter.testBlocked("172.16.0.0")); // MUST block
    try testing.expect(filter.testBlocked("172.31.255.255")); // MUST block
    try testing.expect(!filter.testBlocked("172.32.0.0")); // MUST NOT block

    // RFC1918 192.168.0.0/16
    try testing.expect(filter.testBlocked("192.168.0.1"));
    try testing.expect(!filter.testBlocked("192.169.0.0"));

    // Link-local
    try testing.expect(filter.testBlocked("169.254.1.1"));
    try testing.expect(!filter.testBlocked("169.255.0.0"));

    // Public IP — must NOT be blocked
    try testing.expect(!filter.testBlocked("8.8.8.8"));
    try testing.expect(!filter.testBlocked("1.1.1.1"));
    try testing.expect(!filter.testBlocked("93.184.216.34")); // example.com
}

test "IpFilter: IPv6 CIDR matching: private group" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.testBlocked("::")); // unspecified
    try testing.expect(filter.testBlocked("::1")); // localhost
    try testing.expect(filter.testBlocked("fe80::1")); // link-local
    try testing.expect(filter.testBlocked("fc00::1")); // ULA
    try testing.expect(filter.testBlocked("fd00::1")); // ULA (fd is fc00::/7)
    try testing.expect(!filter.testBlocked("2001:db8::1")); // documentation range — public
    try testing.expect(!filter.testBlocked("2606:4700::1111")); // Cloudflare
}

test "IpFilter: IPv4-mapped IPv6 bypass prevention" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    // ::ffff:127.0.0.1 must be blocked (maps to loopback)
    try testing.expect(filter.testBlocked("::ffff:127.0.0.1"));
    // ::ffff:10.0.0.1 must be blocked (maps to RFC1918)
    try testing.expect(filter.testBlocked("::ffff:10.0.0.1"));
    // ::ffff:8.8.8.8 must NOT be blocked (maps to public)
    try testing.expect(!filter.testBlocked("::ffff:8.8.8.8"));
}

test "IpFilter: fail-closed: unknown address family blocked by isBlockedSockaddr" {
    const filter = IpFilter.init(false, null);
    defer filter.deinit(testing.allocator);

    // Construct a sockaddr with an unknown address family
    var sa: libcurl.CurlSockAddr = .{
        .family = 255, // not AF_INET or AF_INET6
        .socktype = posix.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .addr = undefined,
    };
    try testing.expect(filter.isBlockedSockaddr(&sa));
}

test "IpFilter: custom CIDR ranges" {
    const cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24");
    const filter = IpFilter.init(false, cidrs);
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.testBlocked("203.0.113.1")); // in custom range
    try testing.expect(filter.testBlocked("203.0.113.255")); // in custom range
    try testing.expect(!filter.testBlocked("203.0.114.0")); // outside custom range
    try testing.expect(!filter.testBlocked("8.8.8.8")); // not in range
}

test "IpFilter: private group blocks cloud metadata IP via link-local" {
    // 169.254.169.254 is in link-local (169.254.0.0/16) which is in the private group.
    // Users who want targeted cloud-metadata-only blocking can use --block-cidrs.
    const filter_private = IpFilter.init(true, null);
    defer filter_private.deinit(testing.allocator);
    const filter_none = IpFilter.init(false, null);
    defer filter_none.deinit(testing.allocator);

    try testing.expect(filter_private.testBlocked("169.254.169.254")); // blocked via link-local
    try testing.expect(!filter_none.testBlocked("169.254.169.254")); // not blocked when disabled
}

test "IpFilter: parseCidrList: mixed IPv4 and IPv6" {
    const cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24, 2001:db8::/32, 192.168.1.0/24");

    try testing.expectEqual(2, cidrs.v4.len);
    try testing.expectEqual(1, cidrs.v6.len);

    // spot-check: 203.0.113.0/24 and 192.168.1.0/24
    const f = IpFilter.init(false, cidrs);
    defer f.deinit(testing.allocator);
    try testing.expect(f.testBlocked("203.0.113.1"));
    try testing.expect(!f.testBlocked("203.0.114.0"));
    try testing.expect(f.testBlocked("192.168.1.1"));
    try testing.expect(f.testBlocked("2001:db8::1"));
    try testing.expect(!f.testBlocked("2001:db9::1"));
}

test "IpFilter: allow list exempts from private blocking" {
    const cidrs = try parseCidrList(testing.allocator, "-10.0.0.42/32,-fc00::1/128");
    const filter = IpFilter.init(true, cidrs);
    defer filter.deinit(testing.allocator);

    // Allowed IPs pass through despite being in private ranges
    try testing.expect(!filter.testBlocked("10.0.0.42"));
    try testing.expect(!filter.testBlocked("fc00::1"));

    // Other private IPs still blocked
    try testing.expect(filter.testBlocked("10.0.0.43"));
    try testing.expect(filter.testBlocked("10.0.0.41"));
    try testing.expect(filter.testBlocked("192.168.1.1"));
    try testing.expect(filter.testBlocked("fc00::2"));
}

test "IpFilter: allow list exempts from custom CIDR blocking" {
    const cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24,-203.0.113.100/32");
    const filter = IpFilter.init(false, cidrs);
    defer filter.deinit(testing.allocator);

    try testing.expect(!filter.testBlocked("203.0.113.100")); // allowed
    try testing.expect(filter.testBlocked("203.0.113.99")); // blocked
    try testing.expect(filter.testBlocked("203.0.113.101")); // blocked
}

test "IpFilter: parseCidrList: allow entries with '-' prefix" {
    const cidrs = try parseCidrList(testing.allocator, "10.0.0.0/8,-10.0.0.42/32,-fc00::1/128");

    try testing.expectEqual(1, cidrs.v4.len);
    try testing.expectEqual(0, cidrs.v6.len);
    try testing.expectEqual(1, cidrs.allow_v4.len);
    try testing.expectEqual(1, cidrs.allow_v6.len);

    const f = IpFilter.init(false, cidrs);
    defer f.deinit(testing.allocator);
    try testing.expect(!f.testBlocked("10.0.0.42")); // allowed
    try testing.expect(f.testBlocked("10.0.0.43")); // blocked
    try testing.expect(!f.testBlocked("fc00::1")); // allowed (not blocked by custom, but allow-listed)
}

test "IpFilter: parseCidrList: invalid input returns error" {
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "not-a-cidr"));
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "10.0.0.0/33")); // prefix too large
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "10.0.0.0")); // missing prefix
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "10.0.0.0/abc")); // non-numeric prefix
}

test "IpFilter: matchesCidrV4: exact match /32" {
    const cidr = CidrV4.fromPrefix(.{ 192, 168, 1, 100 }, 32);
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 100 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 101 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 99 }, cidr));
}

test "IpFilter: matchesCidrV4: /0 matches everything" {
    const cidr = CidrV4.fromPrefix(.{ 0, 0, 0, 0 }, 0);
    try testing.expect(matchesCidrV4(.{ 0, 0, 0, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 255, 255, 255, 255 }, cidr));
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 1 }, cidr));
}

test "IpFilter: matchesCidrV4: /8 boundary" {
    const cidr = CidrV4.fromPrefix(.{ 10, 0, 0, 0 }, 8);
    try testing.expect(matchesCidrV4(.{ 10, 0, 0, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 10, 255, 255, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 11, 0, 0, 0 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 9, 255, 255, 255 }, cidr));
}

test "IpFilter: matchesCidrV4: /12 boundary (172.16.0.0/12)" {
    const cidr = CidrV4.fromPrefix(.{ 172, 16, 0, 0 }, 12);
    // In range
    try testing.expect(matchesCidrV4(.{ 172, 16, 0, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 172, 31, 255, 255 }, cidr));
    try testing.expect(matchesCidrV4(.{ 172, 20, 100, 50 }, cidr));
    // Out of range
    try testing.expect(!matchesCidrV4(.{ 172, 15, 255, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 172, 32, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV4: /24 network" {
    const cidr = CidrV4.fromPrefix(.{ 203, 0, 113, 0 }, 24);
    try testing.expect(matchesCidrV4(.{ 203, 0, 113, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 203, 0, 113, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 203, 0, 112, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 203, 0, 114, 0 }, cidr));
}

test "IpFilter: matchesCidrV4: non-byte-aligned /25" {
    const cidr = CidrV4.fromPrefix(.{ 192, 168, 1, 0 }, 25);
    // 192.168.1.0 - 192.168.1.127 should match
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 127 }, cidr));
    // 192.168.1.128+ should not match
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 128 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 255 }, cidr));
}

test "IpFilter: matchesCidrV6: /128 exact match" {
    const addr: Ipv6Addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const cidr = CidrV6.fromPrefix(addr, 128);
    try testing.expect(matchesCidrV6(addr, cidr));

    var different = addr;
    different[15] = 2;
    try testing.expect(!matchesCidrV6(different, cidr));
}

test "IpFilter: matchesCidrV6: /0 matches everything" {
    const cidr = CidrV6.fromPrefix(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 0);
    try testing.expect(matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
}

test "IpFilter: matchesCidrV6: /64 boundary" {
    // 2001:db8::/64
    const cidr = CidrV6.fromPrefix(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 64);
    // In range - any suffix in lower 64 bits
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
    // Out of range - different prefix
    try testing.expect(!matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV6: /48 network" {
    // 2001:db8:abcd::/48
    const cidr = CidrV6.fromPrefix(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 48);
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
    try testing.expect(!matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xce, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV6: /10 link-local (fe80::/10)" {
    const cidr = CidrV6.fromPrefix(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 10);
    // fe80:: through febf:: should match (first 10 bits: 1111111010)
    try testing.expect(matchesCidrV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0xfe, 0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
    // fec0:: should NOT match (11th bit differs)
    try testing.expect(!matchesCidrV6(.{ 0xfe, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV6: prefix > 64 bits (/96)" {
    // ::ffff:0:0/96 (IPv4-mapped prefix)
    const cidr = CidrV6.fromPrefix(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0 }, 96);
    try testing.expect(matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 }, cidr));
    try testing.expect(!matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 192, 168, 1, 1 }, cidr));
}

/// Test-only convenience: parse an IP string and check against the filter.
/// Test inputs must be valid IPs; unreachable on parse failure.
fn testBlocked(self: *const IpFilter, ip: []const u8) bool {
    if (parseIpv4(ip)) |v4| return self.isBlockedV4(v4);
    if (parseIpv6(ip)) |v6| {
        if (isIpv4Mapped(v6)) |v4| return self.isBlockedV4(v4);
        return self.isBlockedV6(v6);
    }
    unreachable;
}

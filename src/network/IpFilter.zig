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
    network: Ipv4Addr,
    prefix_len: u6, // 0-32
};

pub const CidrV6 = struct {
    network: Ipv6Addr,
    prefix_len: u8, // 0-128
};

// IpFilter fields
block_private: bool,
custom_v4: []const CidrV4,
custom_v6: []const CidrV6,
allow_v4: []const CidrV4,
allow_v6: []const CidrV6,

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
    return .{ .network = parseIpv4Comptime(addr), .prefix_len = prefix };
}

/// Comptime helper: build a CidrV6 from a 16-byte literal array.
fn makeCidrV6(comptime bytes: Ipv6Addr, comptime prefix: u8) CidrV6 {
    return .{ .network = bytes, .prefix_len = prefix };
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
    if (cidr.prefix_len == 0) return true;
    const full_bytes: usize = cidr.prefix_len / 8;
    const rem_bits: u4 = @intCast(cidr.prefix_len % 8);

    var i: usize = 0;
    // Check full bytes
    while (i < full_bytes) : (i += 1) {
        if (addr[i] != cidr.network[i]) return false;
    }
    // Check partial byte (if any)
    if (rem_bits > 0 and i < 4) {
        const shift: u3 = @intCast(8 - rem_bits);
        const mask: u8 = @as(u8, 0xFF) << shift;
        if ((addr[i] & mask) != (cidr.network[i] & mask)) return false;
    }
    return true;
}

/// Check if IPv6 address falls within a CIDR range.
fn matchesCidrV6(addr: Ipv6Addr, cidr: CidrV6) bool {
    if (cidr.prefix_len == 0) return true;
    const full_bytes: usize = cidr.prefix_len / 8;
    const rem_bits: u4 = @intCast(cidr.prefix_len % 8);

    var i: usize = 0;
    while (i < full_bytes) : (i += 1) {
        if (addr[i] != cidr.network[i]) return false;
    }
    if (rem_bits > 0 and i < 16) {
        const shift: u3 = @intCast(8 - rem_bits);
        const mask: u8 = @as(u8, 0xFF) << shift;
        if ((addr[i] & mask) != (cidr.network[i] & mask)) return false;
    }
    return true;
}

// ── Public API ───────────────────────────────────────────────────────────────

pub const ParsedCidrs = struct { v4: []CidrV4, v6: []CidrV6, allow_v4: []CidrV4, allow_v6: []CidrV6 };

/// Parse a comma-separated list of CIDR strings (e.g. "10.0.0.0/8,2001:db8::/32")
/// into separate IPv4 and IPv6 slices. Entries prefixed with '-' are added to the
/// allow list (e.g. "-10.0.0.42/32" exempts that IP from blocking).
/// Caller owns the returned slices and must free them with the same allocator.
/// Returns error.InvalidCidr on any malformed entry.
pub fn parseCidrList(
    allocator: std.mem.Allocator,
    cidr_str: []const u8,
) !ParsedCidrs {
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
            const cidr = CidrV4{ .network = v4, .prefix_len = @intCast(prefix) };
            if (is_allow) {
                try allow_v4_list.append(allocator, cidr);
            } else {
                try v4_list.append(allocator, cidr);
            }
        } else if (parseIpv6(addr_str)) |v6| {
            const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidCidr;
            if (prefix > 128) return error.InvalidCidr;
            const cidr = CidrV6{ .network = v6, .prefix_len = prefix };
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

/// Create an IpFilter. Set block_private to block outbound requests to
/// RFC1918, localhost, link-local, and ULA ranges — useful for sandboxing
/// and preventing access to internal infrastructure. custom_v4/custom_v6
/// are additional user-defined ranges to block; allow_v4/allow_v6 are
/// exemptions that take precedence over all block rules.
/// Caller owns the slices.
pub fn init(
    block_private: bool,
    custom_v4: []const CidrV4,
    custom_v6: []const CidrV6,
    allow_v4: []const CidrV4,
    allow_v6: []const CidrV6,
) IpFilter {
    return .{
        .block_private = block_private,
        .custom_v4 = custom_v4,
        .custom_v6 = custom_v6,
        .allow_v4 = allow_v4,
        .allow_v6 = allow_v6,
    };
}

fn isBlockedV4(self: *const IpFilter, addr: Ipv4Addr) bool {
    for (self.allow_v4) |cidr| {
        if (matchesCidrV4(addr, cidr)) return false;
    }
    if (self.block_private) {
        for (PRIVATE_V4) |cidr| {
            if (matchesCidrV4(addr, cidr)) return true;
        }
    }
    for (self.custom_v4) |cidr| {
        if (matchesCidrV4(addr, cidr)) return true;
    }
    return false;
}

fn isBlockedV6(self: *const IpFilter, addr: Ipv6Addr) bool {
    for (self.allow_v6) |cidr| {
        if (matchesCidrV6(addr, cidr)) return false;
    }
    if (self.block_private) {
        for (PRIVATE_V6) |cidr| {
            if (matchesCidrV6(addr, cidr)) return true;
        }
    }
    for (self.custom_v6) |cidr| {
        if (matchesCidrV6(addr, cidr)) return true;
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

// ── Unit tests ───────────────────────────────────────────────────────────────

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

test "IPv4 CIDR matching: private group boundaries" {
    const filter = IpFilter.init(true, &.{}, &.{}, &.{}, &.{});
    const t = std.testing;

    // Loopback
    try t.expect(filter.testBlocked("127.0.0.1"));
    try t.expect(filter.testBlocked("127.255.255.255"));
    try t.expect(!filter.testBlocked("128.0.0.1"));

    // RFC1918 10.0.0.0/8
    try t.expect(filter.testBlocked("10.0.0.1"));
    try t.expect(filter.testBlocked("10.255.255.255"));
    try t.expect(!filter.testBlocked("11.0.0.0"));

    // RFC1918 172.16.0.0/12 — critical boundary
    try t.expect(!filter.testBlocked("172.15.255.255")); // MUST NOT block
    try t.expect(filter.testBlocked("172.16.0.0")); // MUST block
    try t.expect(filter.testBlocked("172.31.255.255")); // MUST block
    try t.expect(!filter.testBlocked("172.32.0.0")); // MUST NOT block

    // RFC1918 192.168.0.0/16
    try t.expect(filter.testBlocked("192.168.0.1"));
    try t.expect(!filter.testBlocked("192.169.0.0"));

    // Link-local
    try t.expect(filter.testBlocked("169.254.1.1"));
    try t.expect(!filter.testBlocked("169.255.0.0"));

    // Public IP — must NOT be blocked
    try t.expect(!filter.testBlocked("8.8.8.8"));
    try t.expect(!filter.testBlocked("1.1.1.1"));
    try t.expect(!filter.testBlocked("93.184.216.34")); // example.com
}

test "IPv6 CIDR matching: private group" {
    const filter = IpFilter.init(true, &.{}, &.{}, &.{}, &.{});
    const t = std.testing;

    try t.expect(filter.testBlocked("::1")); // localhost
    try t.expect(filter.testBlocked("fe80::1")); // link-local
    try t.expect(filter.testBlocked("fc00::1")); // ULA
    try t.expect(filter.testBlocked("fd00::1")); // ULA (fd is fc00::/7)
    try t.expect(!filter.testBlocked("2001:db8::1")); // documentation range — public
    try t.expect(!filter.testBlocked("2606:4700::1111")); // Cloudflare
}

test "IPv4-mapped IPv6 bypass prevention" {
    const filter = IpFilter.init(true, &.{}, &.{}, &.{}, &.{});
    const t = std.testing;

    // ::ffff:127.0.0.1 must be blocked (maps to loopback)
    try t.expect(filter.testBlocked("::ffff:127.0.0.1"));
    // ::ffff:10.0.0.1 must be blocked (maps to RFC1918)
    try t.expect(filter.testBlocked("::ffff:10.0.0.1"));
    // ::ffff:8.8.8.8 must NOT be blocked (maps to public)
    try t.expect(!filter.testBlocked("::ffff:8.8.8.8"));
}

test "fail-closed: unknown address family blocked by isBlockedSockaddr" {
    const filter = IpFilter.init(false, &.{}, &.{}, &.{}, &.{});
    const t = std.testing;

    // Construct a sockaddr with an unknown address family
    var sa: libcurl.CurlSockAddr = .{
        .family = 255, // not AF_INET or AF_INET6
        .socktype = posix.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .addr = undefined,
    };
    try t.expect(filter.isBlockedSockaddr(&sa));
}

test "custom CIDR ranges" {
    const custom_v4 = [_]CidrV4{
        .{ .network = .{ 203, 0, 113, 0 }, .prefix_len = 24 }, // TEST-NET-3
    };
    const filter = IpFilter.init(false, &custom_v4, &.{}, &.{}, &.{});
    const t = std.testing;

    try t.expect(filter.testBlocked("203.0.113.1")); // in custom range
    try t.expect(filter.testBlocked("203.0.113.255")); // in custom range
    try t.expect(!filter.testBlocked("203.0.114.0")); // outside custom range
    try t.expect(!filter.testBlocked("8.8.8.8")); // not in range
}

test "private group blocks cloud metadata IP via link-local" {
    // 169.254.169.254 is in link-local (169.254.0.0/16) which is in the private group.
    // Users who want targeted cloud-metadata-only blocking can use --block_cidrs.
    const filter_private = IpFilter.init(true, &.{}, &.{}, &.{}, &.{});
    const filter_none = IpFilter.init(false, &.{}, &.{}, &.{}, &.{});
    const t = std.testing;

    try t.expect(filter_private.testBlocked("169.254.169.254")); // blocked via link-local
    try t.expect(!filter_none.testBlocked("169.254.169.254")); // not blocked when disabled
}

test "parseCidrList: mixed IPv4 and IPv6" {
    const t = std.testing;
    const result = try parseCidrList(t.allocator, "203.0.113.0/24, 2001:db8::/32, 192.168.1.0/24");
    defer t.allocator.free(result.v4);
    defer t.allocator.free(result.v6);
    defer t.allocator.free(result.allow_v4);
    defer t.allocator.free(result.allow_v6);

    try t.expectEqual(2, result.v4.len);
    try t.expectEqual(1, result.v6.len);

    // spot-check: 203.0.113.0/24 and 192.168.1.0/24
    const f = IpFilter.init(false, result.v4, result.v6, result.allow_v4, result.allow_v6);
    try t.expect(f.testBlocked("203.0.113.1"));
    try t.expect(!f.testBlocked("203.0.114.0"));
    try t.expect(f.testBlocked("192.168.1.1"));
    try t.expect(f.testBlocked("2001:db8::1"));
    try t.expect(!f.testBlocked("2001:db9::1"));
}

test "allow list exempts from private blocking" {
    const allow_v4 = [_]CidrV4{
        .{ .network = .{ 10, 0, 0, 42 }, .prefix_len = 32 },
    };
    const allow_v6 = [_]CidrV6{
        makeCidrV6(.{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 128),
    };
    const filter = IpFilter.init(true, &.{}, &.{}, &allow_v4, &allow_v6);
    const t = std.testing;

    // Allowed IPs pass through despite being in private ranges
    try t.expect(!filter.testBlocked("10.0.0.42"));
    try t.expect(!filter.testBlocked("fc00::1"));

    // Other private IPs still blocked
    try t.expect(filter.testBlocked("10.0.0.43"));
    try t.expect(filter.testBlocked("10.0.0.41"));
    try t.expect(filter.testBlocked("192.168.1.1"));
    try t.expect(filter.testBlocked("fc00::2"));
}

test "allow list exempts from custom CIDR blocking" {
    const custom_v4 = [_]CidrV4{
        .{ .network = .{ 203, 0, 113, 0 }, .prefix_len = 24 },
    };
    const allow_v4 = [_]CidrV4{
        .{ .network = .{ 203, 0, 113, 100 }, .prefix_len = 32 },
    };
    const filter = IpFilter.init(false, &custom_v4, &.{}, &allow_v4, &.{});
    const t = std.testing;

    try t.expect(!filter.testBlocked("203.0.113.100")); // allowed
    try t.expect(filter.testBlocked("203.0.113.99")); // blocked
    try t.expect(filter.testBlocked("203.0.113.101")); // blocked
}

test "parseCidrList: allow entries with '-' prefix" {
    const t = std.testing;
    const result = try parseCidrList(t.allocator, "10.0.0.0/8,-10.0.0.42/32,-fc00::1/128");
    defer t.allocator.free(result.v4);
    defer t.allocator.free(result.v6);
    defer t.allocator.free(result.allow_v4);
    defer t.allocator.free(result.allow_v6);

    try t.expectEqual(1, result.v4.len);
    try t.expectEqual(0, result.v6.len);
    try t.expectEqual(1, result.allow_v4.len);
    try t.expectEqual(1, result.allow_v6.len);

    const f = IpFilter.init(false, result.v4, result.v6, result.allow_v4, result.allow_v6);
    try t.expect(!f.testBlocked("10.0.0.42")); // allowed
    try t.expect(f.testBlocked("10.0.0.43")); // blocked
    try t.expect(!f.testBlocked("fc00::1")); // allowed (not blocked by custom, but allow-listed)
}

test "parseCidrList: invalid input returns error" {
    const t = std.testing;
    try t.expectError(error.InvalidCidr, parseCidrList(t.allocator, "not-a-cidr"));
    try t.expectError(error.InvalidCidr, parseCidrList(t.allocator, "10.0.0.0/33")); // prefix too large
    try t.expectError(error.InvalidCidr, parseCidrList(t.allocator, "10.0.0.0")); // missing prefix
    try t.expectError(error.InvalidCidr, parseCidrList(t.allocator, "10.0.0.0/abc")); // non-numeric prefix
}

test {
    std.testing.refAllDecls(@This());
}

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

//! Shared helpers for the SubtleCrypto algorithms: usage-mask validation, the
//! base64url codec used by the JWK format, and the JWK checks every
//! algorithm's import makes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const crypto = @import("../../../sys/libcrypto.zig");
const js = @import("../../js/js.zig");
const CryptoKey = @import("../CryptoKey.zig");
const algorithm = @import("algorithm.zig");
const Execution = js.Execution;

/// The hashes the algorithms take (their `hash` member).
pub const hashes = [_][]const u8{ "SHA-1", "SHA-256", "SHA-384", "SHA-512" };

/// The registered hash name (case-insensitive), or null if not a supported
/// hash. Stored on the key, so `.algorithm.hash.name` reports it and
/// `findDigest` (which is case-sensitive) can look it up.
pub fn canonicalHash(name: []const u8) ?[]const u8 {
    for (hashes) |canonical| {
        if (std.ascii.eqlIgnoreCase(name, canonical)) return canonical;
    }
    return null;
}

/// Maps a usage string to its `CryptoKey.Usages` bit, or null if unknown.
pub fn usageBit(name: []const u8) ?u8 {
    const U = CryptoKey.Usages;
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "encrypt", U.encrypt },
        .{ "decrypt", U.decrypt },
        .{ "sign", U.sign },
        .{ "verify", U.verify },
        .{ "deriveKey", U.deriveKey },
        .{ "deriveBits", U.deriveBits },
        .{ "wrapKey", U.wrapKey },
        .{ "unwrapKey", U.unwrapKey },
    });
    return map.get(name);
}

/// Builds the usage bitmask, rejecting any usage not in `allowed` with
/// SyntaxError — matching the WebCrypto "Bad usages" failure path. An empty
/// list is also a SyntaxError (the "Empty usages" path), which is correct for
/// secret and private keys; public keys permit empty usages.
pub fn usageMask(allowed: []const []const u8, usages: []const []const u8) error{SyntaxError}!u8 {
    return usageMaskInner(allowed, usages, true);
}

/// As `usageMask`, but `reject_empty` controls whether an empty usage list is a
/// SyntaxError. Pass false for public keys.
pub fn usageMaskInner(allowed: []const []const u8, usages: []const []const u8, reject_empty: bool) error{SyntaxError}!u8 {
    var mask: u8 = 0;
    outer: for (usages) |usage| {
        for (allowed) |a| {
            if (std.mem.eql(u8, a, usage)) {
                mask |= usageBit(a).?;
                continue :outer;
            }
        }
        return error.SyntaxError;
    }
    if (reject_empty and usages.len == 0) {
        return error.SyntaxError;
    }
    return mask;
}

/// Whether `usage` is one of `set`.
pub fn usageIn(set: []const []const u8, usage: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, usage)) return true;
    }
    return false;
}

/// The usage intersection of `usages` and `set`, as a bitmask: how a key
/// pair's usages are split between its halves.
pub fn usageIntersection(set: []const []const u8, usages: []const []const u8) u8 {
    var mask: u8 = 0;
    for (usages) |usage| {
        if (usageIn(set, usage)) mask |= usageBit(usage).?;
    }
    return mask;
}

/// The key bytes of a symmetric ("oct") JWK: its `kty` must be "oct" and its
/// `k` present and decodable (JWA, section 6.4). Anything else is DataError.
pub fn octKey(jwk: algorithm.KeyData.Jwk, allocator: Allocator) error{ OutOfMemory, DataError }![]u8 {
    if (!std.mem.eql(u8, jwk.kty orelse "", "oct")) return error.DataError;
    return base64Decode(allocator, jwk.k orelse return error.DataError);
}

/// The JWK checks shared by every algorithm's "import key": `use` must be
/// `expected_use` ("enc" or "sig") when usages are requested, `key_ops` must
/// hold every requested usage and no value twice (RFC 7517, section 4.3;
/// values that aren't usages are allowed), and a JWK with `ext: false` can't be
/// imported as extractable. `kty`, the key members and `alg` are each
/// algorithm's own.
pub fn checkJwk(
    jwk: algorithm.KeyData.Jwk,
    expected_use: []const u8,
    usages_mask: u8,
    extractable: bool,
) error{DataError}!void {
    if (jwk.use) |use| {
        if (usages_mask != 0 and !std.mem.eql(u8, use, expected_use)) return error.DataError;
    }
    if (jwk.key_ops) |key_ops| {
        var listed: u8 = 0;
        for (key_ops, 0..) |op, i| {
            for (key_ops[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier, op)) return error.DataError;
            }
            if (usageBit(op)) |bit| listed |= bit;
        }
        if (usages_mask & ~listed != 0) return error.DataError;
    }
    if (jwk.ext) |ext| {
        if (!ext and extractable) return error.DataError;
    }
}

/// The first `length_in_bits` bits of a derived `secret`, all of it when null:
/// whole bytes, with the unused low bits of a partial last byte zeroed. A
/// length beyond the secret is OperationError.
pub fn leadingBits(secret: []u8, length_in_bits: ?u32) error{OperationError}![]u8 {
    const bits = length_in_bits orelse return secret;
    const byte_len = (@as(usize, bits) + 7) / 8;
    if (byte_len > secret.len) {
        return error.OperationError;
    }
    const out = secret[0..byte_len];
    const remainder_bits: u3 = @intCast(bits % 8);
    if (remainder_bits != 0) {
        out[out.len - 1] &= ~(@as(u8, 0xFF) >> remainder_bits);
    }
    return out;
}

/// A JWK key member (a coordinate, `x`, `d`, ...): base64url of exactly `n`
/// bytes. A missing member or one of another size is DataError.
pub fn jwkBytes(allocator: Allocator, member: ?[]const u8, n: usize) error{ OutOfMemory, DataError }![]u8 {
    const bytes = try base64Decode(allocator, member orelse return error.DataError);
    if (bytes.len != n) return error.DataError;
    return bytes;
}

/// Decodes a base64url (or base64) string, tolerating either alphabet and
/// optional padding. Returns DataError on malformed input, per the JWK import
/// rules.
pub fn base64Decode(allocator: Allocator, input: []const u8) error{ OutOfMemory, DataError }![]u8 {
    // Normalize to base64url-no-pad: map the standard alphabet's +/ to -_ and
    // drop any '=' padding so a single decoder handles both forms.
    const normalized = try allocator.alloc(u8, input.len);
    var n: usize = 0;
    for (input) |c| {
        normalized[n] = switch (c) {
            '+' => '-',
            '/' => '_',
            '=' => continue,
            else => c,
        };
        n += 1;
    }

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(normalized[0..n]) catch return error.DataError;
    const out = try allocator.alloc(u8, size);
    decoder.decode(out, normalized[0..n]) catch return error.DataError;
    return out;
}

/// Encodes bytes as base64url without padding (the JWK `k` representation).
pub fn base64Encode(allocator: Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

/// Parses the DER of an asymmetric key (RSA, EC, OKP): a SubjectPublicKeyInfo for
/// `spki`, a PrivateKeyInfo for `pkcs8`. Anything libcrypto can't parse as
/// exactly that structure, trailing bytes included, is DataError, as in
/// Chrome. The caller checks the key's type and frees it.
pub fn parseDer(format: []const u8, der: []const u8) error{ DataError, NotSupported }!*crypto.EVP_PKEY {
    var cbs: crypto.CBS = .{ .data = der.ptr, .len = der.len };
    const pkey = blk: {
        if (std.mem.eql(u8, format, "spki")) break :blk crypto.EVP_parse_public_key(&cbs);
        if (std.mem.eql(u8, format, "pkcs8")) break :blk crypto.EVP_parse_private_key(&cbs);
        return error.NotSupported;
    } orelse {
        crypto.ERR_clear_error();
        return error.DataError;
    };
    if (cbs.len != 0) {
        crypto.EVP_PKEY_free(pkey);
        return error.DataError;
    }
    return pkey;
}

/// Exports an asymmetric key (RSA, EC) as DER: `spki` for a public key,
/// `pkcs8` for a private one. Asking for the other half's format is
/// InvalidAccessError.
pub fn exportDer(format: []const u8, key: *const CryptoKey, exec: *const Execution) ![]const u8 {
    const public = std.mem.eql(u8, format, "spki");
    if (key._kind != (if (public) CryptoKey.Kind.public else CryptoKey.Kind.private)) {
        return error.InvalidAccessError;
    }
    return pkeyDer(key.getKeyObject(), public, exec.local_arena);
}

/// `pkey` as DER, in `allocator`: its SPKI if `public`, otherwise its PKCS#8.
pub fn pkeyDer(pkey: *crypto.EVP_PKEY, public: bool, allocator: std.mem.Allocator) ![]const u8 {
    var out: [*c]u8 = null;
    const len = blk: {
        if (public) {
            break :blk crypto.i2d_PUBKEY(pkey, &out);
        }
        const info = crypto.EVP_PKEY2PKCS8(pkey) orelse return error.OperationError;
        defer crypto.PKCS8_PRIV_KEY_INFO_free(info);
        break :blk crypto.i2d_PKCS8_PRIV_KEY_INFO(info, &out);
    };
    defer crypto.OPENSSL_free(out);
    if (len <= 0) return error.OperationError;

    return allocator.dupe(u8, out[0..@intCast(len)]);
}

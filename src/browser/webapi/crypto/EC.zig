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

//! ECDSA / ECDH key generation, import (spki/pkcs8 via DER) and ECDH key
//! agreement. Key bytes live as a libcrypto EVP_PKEY in `CryptoKey._vary.pkey`.

const std = @import("std");
const crypto = @import("../../../sys/libcrypto.zig");

const js = @import("../../js/js.zig");
const CryptoKey = @import("../CryptoKey.zig");

const common = @import("common.zig");
const algorithm = @import("algorithm.zig");

const Execution = js.Execution;

/// Errors mapped to DOMException names by the caller.
pub const Error = error{ InvalidAccessError, NotSupported, OperationError, OutOfMemory };

/// The registered name (case-insensitive), or null if not an EC algorithm.
pub fn canonicalName(name: []const u8) ?[]const u8 {
    inline for ([_][]const u8{ "ECDSA", "ECDH" }) |canonical| {
        if (eqlIgnoreCase(name, canonical)) return canonical;
    }
    return null;
}

fn curveNid(named_curve: []const u8) ?c_int {
    if (eqlIgnoreCase(named_curve, "P-256")) return crypto.NID_X9_62_prime256v1;
    if (eqlIgnoreCase(named_curve, "P-384")) return crypto.NID_secp384r1;
    if (eqlIgnoreCase(named_curve, "P-521")) return crypto.NID_secp521r1;
    return null;
}

fn curveCanonical(named_curve: []const u8) ?[]const u8 {
    inline for ([_][]const u8{ "P-256", "P-384", "P-521" }) |c| {
        if (eqlIgnoreCase(named_curve, c)) return c;
    }
    return null;
}

/// The (private, public) usages legal for the algorithm.
fn usageSets(name: []const u8) struct { private: []const []const u8, public: []const []const u8 } {
    if (eqlIgnoreCase(name, "ECDSA")) {
        return .{ .private = &.{"sign"}, .public = &.{"verify"} };
    }
    // ECDH
    return .{ .private = &.{ "deriveKey", "deriveBits" }, .public = &.{} };
}

pub fn validate(params: algorithm.Init.EcKeyGen, key_usages: []const []const u8) !void {
    const sets = blk: {
        if (eqlIgnoreCase(params.name, "ECDSA") or eqlIgnoreCase(params.name, "ECDH")) break :blk usageSets(params.name);
        return error.NotSupported;
    };
    // A usage that belongs to neither the private nor the public set is illegal.
    for (key_usages) |usage| {
        if (!contains(sets.private, usage) and !contains(sets.public, usage)) {
            return error.SyntaxError;
        }
    }

    if (curveNid(params.namedCurve) == null) {
        // Per spec, an unsupported `namedCurve` is NotSupportedError.
        return error.NotSupported;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

/// Generates an EC key pair on the requested curve.
pub fn generate(
    params: algorithm.Init.EcKeyGen,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    validate(params, key_usages) catch |err| {
        return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
    };

    const name = canonicalName(params.name).?;
    const curve = curveCanonical(params.namedCurve).?;
    const nid = curveNid(params.namedCurve).?;
    const sets = usageSets(name);

    // Split the requested usages across the pair: each key keeps only the
    // usages legal for it. validate() already rejected anything illegal.
    const private_mask = maskOf(sets.private, key_usages);
    const public_mask = maskOf(sets.public, key_usages);

    const ec = crypto.EC_KEY_new_by_curve_name(nid) orelse return error.OutOfMemory;
    defer crypto.EC_KEY_free(ec);
    if (crypto.EC_KEY_generate_key(ec) != 1) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.OperationError } });
    }

    const private_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(private_pkey);
    if (crypto.EVP_PKEY_set1_EC_KEY(private_pkey, ec) != 1) return error.OutOfMemory;

    // A public-only EVP_PKEY (same curve, just the public point) for the peer.
    const pub_ec = crypto.EC_KEY_new_by_curve_name(nid) orelse return error.OutOfMemory;
    defer crypto.EC_KEY_free(pub_ec);
    const point = crypto.EC_KEY_get0_public_key(ec) orelse return error.OperationError;
    if (crypto.EC_KEY_set_public_key(pub_ec, point) != 1) return error.OperationError;
    const public_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(public_pkey);
    if (crypto.EVP_PKEY_set1_EC_KEY(public_pkey, pub_ec) != 1) return error.OutOfMemory;

    const private = try CryptoKey.init(exec, .{
        ._type = .ec,
        ._kind = .private,
        ._extractable = extractable,
        ._usages = private_mask,
        ._key = &.{},
        ._algorithm = .{ .name = name, .named_curve = curve },
        ._vary = .{ .pkey = private_pkey },
    });

    const public = try CryptoKey.init(exec, .{
        ._type = .ec,
        ._kind = .public,
        // Public keys are always extractable.
        ._extractable = true,
        ._usages = public_mask,
        ._key = &.{},
        ._algorithm = .{ .name = name, .named_curve = curve },
        ._vary = .{ .pkey = public_pkey },
    });

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports an EC key from DER (`spki` public / `pkcs8` private). jwk/raw aren't
/// handled yet. libcrypto parses the DER, so a malformed structure is DataError.
pub fn import(
    name: []const u8,
    named_curve: []const u8,
    format: []const u8,
    der: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const canonical = canonicalName(name).?;
    const curve = curveCanonical(named_curve) orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };

    var ptr: [*c]const u8 = der.ptr;
    const pkey: *crypto.EVP_PKEY = blk: {
        if (std.mem.eql(u8, format, "spki")) {
            break :blk crypto.d2i_PUBKEY(null, &ptr, @intCast(der.len)) orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
        }
        if (std.mem.eql(u8, format, "pkcs8")) {
            break :blk crypto.d2i_AutoPrivateKey(null, &ptr, @intCast(der.len)) orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
        }
        // jwk / raw not implemented yet.
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };
    errdefer crypto.EVP_PKEY_free(pkey);

    if (crypto.EVP_PKEY_id(pkey) != crypto.EVP_PKEY_EC) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    }

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .ec,
        ._kind = if (is_private) .private else .public,
        ._extractable = extractable,
        ._usages = usages_mask,
        ._key = &.{},
        ._algorithm = .{ .name = canonical, .named_curve = curve },
        ._vary = .{ .pkey = pkey },
    });

    return local.resolvePromise(crypto_key);
}

/// ECDH key agreement: derive `length_in_bits` from `private` + the peer
/// `public`. Mirrors X25519's truncation rules.
pub fn deriveBits(
    private: *const CryptoKey,
    public: *const CryptoKey,
    length_in_bits: ?u32,
    exec: *const Execution,
) Error![]const u8 {
    // The peer must be an ECDH *public* key on the *same* curve.
    if (public._type != .ec or public._kind != .public) {
        return error.InvalidAccessError;
    }
    if (!eqlIgnoreCase(public._algorithm.name, "ECDH")) {
        return error.InvalidAccessError;
    }
    if (!eqlIgnoreCase(private._algorithm.named_curve orelse "", public._algorithm.named_curve orelse "")) {
        return error.InvalidAccessError;
    }

    const ctx = crypto.EVP_PKEY_CTX_new(private.getKeyObject(), null) orelse return error.OperationError;
    defer crypto.EVP_PKEY_CTX_free(ctx);

    if (crypto.EVP_PKEY_derive_init(ctx) != 1 or crypto.EVP_PKEY_derive_set_peer(ctx, public.getKeyObject()) != 1) {
        return error.OperationError;
    }

    // First call with a null buffer reports the full shared-secret length.
    var secret_len: usize = 0;
    if (crypto.EVP_PKEY_derive(ctx, null, &secret_len) != 1 or secret_len == 0) {
        return error.OperationError;
    }
    const secret = try exec.local_arena.alloc(u8, secret_len);
    if (crypto.EVP_PKEY_derive(ctx, secret.ptr, &secret_len) != 1) {
        return error.OperationError;
    }

    // null length means "the full shared secret".
    const bits = length_in_bits orelse @as(u32, @intCast(secret_len * 8));
    const byte_len = (bits + 7) / 8;
    if (byte_len > secret_len) {
        return error.OperationError;
    }
    const out = secret[0..byte_len];

    // Zero the unused trailing bits of the final byte.
    const remainder_bits: u3 = @intCast(bits % 8);
    if (remainder_bits != 0 and out.len > 0) {
        out[out.len - 1] &= ~(@as(u8, 0xFF) >> remainder_bits);
    }
    return out;
}

fn contains(set: []const []const u8, usage: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, usage)) {
            return true;
        }
    }
    return false;
}

/// The usage bitmask of those `usages` that belong to `set`.
fn maskOf(set: []const []const u8, usages: []const []const u8) u8 {
    var mask: u8 = 0;
    for (usages) |u| {
        if (contains(set, u)) {
            mask |= common.usageBit(u).?;
        }
    }
    return mask;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

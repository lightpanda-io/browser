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

//! ECDSA / ECDH key generation, import and export (spki/pkcs8 DER, raw public
//! points and JWK), ECDSA sign and verify, and ECDH key agreement. Key bytes
//! live as a libcrypto EVP_PKEY in `CryptoKey._vary.pkey`.

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

/// A curve ECDSA and ECDH keys can be on.
const Curve = struct {
    /// The registered `namedCurve`, also the JWK `crv`.
    name: []const u8,
    nid: c_int,
    /// The size in bytes of a coordinate, and of the private scalar.
    size: usize,
    /// The JWK `alg` of an ECDSA key on the curve (JWA, section 3.1).
    jwk_alg: []const u8,
};

const curves = [_]Curve{
    .{ .name = "P-256", .nid = crypto.NID_X9_62_prime256v1, .size = 32, .jwk_alg = "ES256" },
    .{ .name = "P-384", .nid = crypto.NID_secp384r1, .size = 48, .jwk_alg = "ES384" },
    .{ .name = "P-521", .nid = crypto.NID_secp521r1, .size = 66, .jwk_alg = "ES512" },
};

/// The curve of a `namedCurve` (case-insensitive), or null if it isn't one.
fn curveOf(named_curve: []const u8) ?*const Curve {
    for (&curves) |*c| {
        if (eqlIgnoreCase(named_curve, c.name)) return c;
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
        if (!common.usageIn(sets.private, usage) and !common.usageIn(sets.public, usage)) {
            return error.SyntaxError;
        }
    }

    if (curveOf(params.namedCurve) == null) {
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
    try validate(params, key_usages);

    const name = canonicalName(params.name).?;
    const curve = curveOf(params.namedCurve).?;
    const sets = usageSets(name);

    // Split the requested usages across the pair: each key keeps only the
    // usages legal for it. validate() already rejected anything illegal.
    const private_mask = common.usageIntersection(sets.private, key_usages);
    const public_mask = common.usageIntersection(sets.public, key_usages);

    const ec = crypto.EC_KEY_new_by_curve_name(curve.nid) orelse return error.OutOfMemory;
    defer crypto.EC_KEY_free(ec);
    if (crypto.EC_KEY_generate_key(ec) != 1) {
        return error.OperationError;
    }

    const private_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(private_pkey);
    if (crypto.EVP_PKEY_set1_EC_KEY(private_pkey, ec) != 1) return error.OutOfMemory;

    // A public-only EVP_PKEY (same curve, just the public point) for the peer.
    const pub_ec = crypto.EC_KEY_new_by_curve_name(curve.nid) orelse return error.OutOfMemory;
    defer crypto.EC_KEY_free(pub_ec);
    const point = crypto.EC_KEY_get0_public_key(ec) orelse return error.OperationError;
    if (crypto.EC_KEY_set_public_key(pub_ec, point) != 1) return error.OperationError;
    const public_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(public_pkey);
    if (crypto.EVP_PKEY_set1_EC_KEY(public_pkey, pub_ec) != 1) return error.OutOfMemory;

    const private = try newKey(private_pkey, name, curve.name, true, extractable, private_mask, exec);
    // Public keys are always extractable.
    const public = try newKey(public_pkey, name, curve.name, false, true, public_mask, exec);

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports an EC key from `spki` (public) or `pkcs8` (private) DER, or from a
/// `raw` public point (SEC 1: uncompressed or compressed). A malformed
/// structure (common.parseDer), a point that isn't on the curve, or a key on
/// another curve than `named_curve` is DataError. JWK goes through
/// `importJwk`.
pub fn import(
    name: []const u8,
    named_curve: []const u8,
    format: []const u8,
    data: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const canonical = canonicalName(name).?;
    const curve = curveOf(named_curve) orelse {
        return error.NotSupported;
    };

    const pkey = if (std.mem.eql(u8, format, "raw"))
        try keyFromPoint(curve, data, null)
    else
        try common.parseDer(format, data);
    errdefer crypto.EVP_PKEY_free(pkey);

    if (crypto.EVP_PKEY_id(pkey) != crypto.EVP_PKEY_EC) {
        return error.DataError;
    }
    const ec = crypto.EVP_PKEY_get0_EC_KEY(pkey) orelse return error.DataError;
    const group = crypto.EC_KEY_get0_group(ec) orelse return error.DataError;
    if (crypto.EC_GROUP_get_curve_name(group) != curve.nid) {
        return error.DataError;
    }
    // A private key whose public point doesn't match its scalar, say.
    if (crypto.EC_KEY_check_key(ec) != 1) {
        crypto.ERR_clear_error();
        return error.DataError;
    }

    return local.resolvePromise(try newKey(pkey, canonical, curve.name, is_private, extractable, usages_mask, exec));
}

/// Imports an EC key from a JSON Web Key: `crv`, `x` and `y` for a public key,
/// plus `d` for a private one (the presence of `d` decides, as in
/// SubtleCrypto.importKind, which already validated the usages against it).
/// Follows the "jwk" steps of ECDSA's and ECDH's "import key": kty "EC", the
/// common use ("sig" for ECDSA, "enc" for ECDH) / key_ops / ext checks, `crv`
/// equal to the requested curve and, for ECDSA, an `alg` naming it (ES256,
/// ...); then coordinates of the curve's size that make a valid key. Anything
/// else is DataError.
pub fn importJwk(
    name: []const u8,
    named_curve: []const u8,
    jwk: algorithm.KeyData.Jwk,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const canonical = canonicalName(name).?;
    const curve = curveOf(named_curve) orelse return error.NotSupported;
    const is_ecdsa = std.mem.eql(u8, canonical, "ECDSA");

    if (!std.mem.eql(u8, jwk.kty orelse "", "EC")) return error.DataError;
    try common.checkJwk(jwk, if (is_ecdsa) "sig" else "enc", usages_mask, extractable);
    // `crv` and `alg` are matched case-sensitively; ECDH ignores `alg`.
    if (!std.mem.eql(u8, jwk.crv orelse "", curve.name)) return error.DataError;
    if (is_ecdsa) {
        if (jwk.alg) |alg| {
            if (!std.mem.eql(u8, alg, curve.jwk_alg)) return error.DataError;
        }
    }

    // The public point, uncompressed: 0x04 || x || y.
    const n = curve.size;
    const point = try exec.local_arena.alloc(u8, 1 + 2 * n);
    point[0] = 0x04;
    @memcpy(point[1 .. 1 + n], try common.jwkBytes(exec.local_arena, jwk.x, n));
    @memcpy(point[1 + n ..], try common.jwkBytes(exec.local_arena, jwk.y, n));
    const d = if (jwk.d) |member| try common.jwkBytes(exec.local_arena, member, n) else null;

    const pkey = try keyFromPoint(curve, point, d);
    errdefer crypto.EVP_PKEY_free(pkey);
    return local.resolvePromise(try newKey(pkey, canonical, curve.name, d != null, extractable, usages_mask, exec));
}

/// An EC EVP_PKEY on `curve` from an encoded public point and, for a private
/// key, its scalar. A point not on the curve, or a scalar that doesn't match
/// it, is DataError.
fn keyFromPoint(curve: *const Curve, point: []const u8, private: ?[]const u8) !*crypto.EVP_PKEY {
    const ec = crypto.EC_KEY_new_by_curve_name(curve.nid) orelse return error.OutOfMemory;
    defer crypto.EC_KEY_free(ec);
    const group = crypto.EC_KEY_get0_group(ec) orelse return error.OperationError;

    const pub_point = crypto.EC_POINT_new(group) orelse return error.OutOfMemory;
    defer crypto.EC_POINT_free(pub_point);
    if (point.len == 0 or crypto.EC_POINT_oct2point(group, pub_point, point.ptr, point.len, null) != 1) {
        crypto.ERR_clear_error();
        return error.DataError;
    }
    if (crypto.EC_KEY_set_public_key(ec, pub_point) != 1) return error.DataError;

    if (private) |scalar| {
        const bn = crypto.BN_bin2bn(scalar.ptr, scalar.len, null) orelse return error.OutOfMemory;
        defer crypto.BN_free(bn);
        if (crypto.EC_KEY_set_private_key(ec, bn) != 1) {
            crypto.ERR_clear_error();
            return error.DataError;
        }
    }
    if (crypto.EC_KEY_check_key(ec) != 1) {
        crypto.ERR_clear_error();
        return error.DataError;
    }

    const pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(pkey);
    if (crypto.EVP_PKEY_set1_EC_KEY(pkey, ec) != 1) return error.OutOfMemory;
    return pkey;
}

/// Wraps an EC `pkey` in a CryptoKey. The key takes ownership of `pkey` only
/// on success.
fn newKey(
    pkey: *crypto.EVP_PKEY,
    name: []const u8,
    curve: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !*CryptoKey {
    return CryptoKey.init(exec, .{
        ._type = .ec,
        ._kind = if (is_private) .private else .public,
        ._extractable = extractable,
        ._usages = usages_mask,
        ._key = &.{},
        ._algorithm = .{ .name = name, .named_curve = curve },
        ._vary = .{ .pkey = pkey },
    });
}

/// The public point of an EC key, uncompressed (0x04 || x || y): the `raw`
/// export, and the source of a JWK's `x` and `y`.
pub fn exportRaw(key: *const CryptoKey, exec: *const Execution) ![]const u8 {
    const ec = crypto.EVP_PKEY_get0_EC_KEY(key.getKeyObject()) orelse return error.OperationError;
    const group = crypto.EC_KEY_get0_group(ec) orelse return error.OperationError;
    const point = crypto.EC_KEY_get0_public_key(ec) orelse return error.OperationError;
    const len = crypto.EC_POINT_point2oct(group, point, crypto.POINT_CONVERSION_UNCOMPRESSED, null, 0, null);
    if (len == 0) return error.OperationError;
    const out = try exec.local_arena.alloc(u8, len);
    if (crypto.EC_POINT_point2oct(group, point, crypto.POINT_CONVERSION_UNCOMPRESSED, out.ptr, out.len, null) != len) {
        return error.OperationError;
    }
    return out;
}

/// The JWK of an EC key (JWA, section 6.2). Members are listed in
/// lexicographic order, the order browsers return a JsonWebKey in; there's no
/// `alg`, as browsers don't set one either.
const JwkPublic = struct {
    crv: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "EC",
    x: []const u8,
    y: []const u8,
};

const JwkPrivate = struct {
    crv: []const u8,
    d: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "EC",
    x: []const u8,
    y: []const u8,
};

/// The JWK of either half of an EC key.
pub const Jwk = union(enum) {
    public: JwkPublic,
    private: JwkPrivate,
};

/// Exports an EC key as a JWK: `crv`, `x` and `y` for either half, plus `d`
/// for the private key, each coordinate of the curve's size.
pub fn exportJwk(key: *const CryptoKey, exec: *const Execution) !Jwk {
    const curve = curveOf(key._algorithm.named_curve orelse "") orelse return error.OperationError;
    const n = curve.size;
    const point = try exportRaw(key, exec);
    if (point.len != 1 + 2 * n) return error.OperationError;
    const x = try common.base64Encode(exec.local_arena, point[1 .. 1 + n]);
    const y = try common.base64Encode(exec.local_arena, point[1 + n ..]);
    const key_ops = try key.getUsages(exec);

    if (key._kind == .public) {
        return .{ .public = .{ .crv = curve.name, .ext = key._extractable, .key_ops = key_ops, .x = x, .y = y } };
    }
    const ec = crypto.EVP_PKEY_get0_EC_KEY(key.getKeyObject()) orelse return error.OperationError;
    const scalar = crypto.EC_KEY_get0_private_key(ec) orelse return error.OperationError;
    const d = try exec.local_arena.alloc(u8, n);
    if (crypto.BN_bn2bin_padded(d.ptr, n, scalar) != 1) return error.OperationError;
    return .{ .private = .{
        .crv = curve.name,
        .d = try common.base64Encode(exec.local_arena, d),
        .ext = key._extractable,
        .key_ops = key_ops,
        .x = x,
        .y = y,
    } };
}

/// ECDH key agreement: derive `length_in_bits` from `private` + the peer
/// `public` (common.leadingBits, as X25519).
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
    return common.leadingBits(secret[0..secret_len], length_in_bits);
}

/// The size in bytes of each of r and s in an ECDSA signature with `ec`: that
/// of its curve's order (32, 48 and 66 for P-256, P-384 and P-521). Read from
/// the key itself rather than its `namedCurve`.
fn scalarBytes(ec: *const crypto.EC_KEY) ?usize {
    const group = crypto.EC_KEY_get0_group(ec) orelse return null;
    const order = crypto.EC_GROUP_get0_order(group) orelse return null;
    return crypto.BN_num_bytes(order);
}

/// ECDSA signature generation (FIPS 186-5, section 6.4.1) of `data` hashed
/// with `hash_name`, the hash of the operation's params (not of the key). The
/// signature is r followed by s, each a big-endian integer of the curve
/// order's size: the IEEE P1363 form WebCrypto uses, not DER. SubtleCrypto.sign
/// checked the algorithm and the sign usage; only a private key signs.
pub fn sign(key: *const CryptoKey, data: []const u8, hash_name: []const u8, exec: *const Execution) ![]const u8 {
    if (key._kind != .private) return error.InvalidAccessError;
    const ec = crypto.EVP_PKEY_get0_EC_KEY(key.getKeyObject()) orelse return error.OperationError;
    const n = scalarBytes(ec) orelse return error.OperationError;

    var buf: [crypto.EVP_MAX_MD_SIZE]u8 = undefined;
    const digest = try digestOf(data, hash_name, &buf);
    const sig = crypto.ECDSA_do_sign(digest.ptr, digest.len, ec) orelse return error.OperationError;
    defer crypto.ECDSA_SIG_free(sig);

    var r: ?*const crypto.BIGNUM = null;
    var s: ?*const crypto.BIGNUM = null;
    crypto.ECDSA_SIG_get0(sig, &r, &s);
    const out = try exec.local_arena.alloc(u8, 2 * n);
    if (crypto.BN_bn2bin_padded(out.ptr, n, r orelse return error.OperationError) != 1) return error.OperationError;
    if (crypto.BN_bn2bin_padded(out[n..].ptr, n, s orelse return error.OperationError) != 1) return error.OperationError;
    return out;
}

/// ECDSA signature verification (FIPS 186-5, section 6.4.2) of `signature`
/// (r followed by s, as `sign` produces) over `data` hashed with `hash_name`.
/// SubtleCrypto.verify checked the algorithm and the verify usage; only a
/// public key verifies. A signature that doesn't match is false, whatever its
/// length: one with extra padding, for one, isn't of the curve's size.
pub fn verify(key: *const CryptoKey, signature: []const u8, data: []const u8, hash_name: []const u8) !bool {
    if (key._kind != .public) return error.InvalidAccessError;
    const ec = crypto.EVP_PKEY_get0_EC_KEY(key.getKeyObject()) orelse return error.OperationError;
    const n = scalarBytes(ec) orelse return error.OperationError;

    var buf: [crypto.EVP_MAX_MD_SIZE]u8 = undefined;
    const digest = try digestOf(data, hash_name, &buf);
    if (signature.len != 2 * n) {
        return false;
    }

    const sig = crypto.ECDSA_SIG_new() orelse return error.OutOfMemory;
    defer crypto.ECDSA_SIG_free(sig);
    const r = crypto.BN_bin2bn(signature.ptr, n, null) orelse return error.OutOfMemory;
    const s = crypto.BN_bin2bn(signature[n..].ptr, n, null) orelse {
        crypto.BN_free(r);
        return error.OutOfMemory;
    };
    if (crypto.ECDSA_SIG_set0(sig, r, s) != 1) {
        crypto.BN_free(r);
        crypto.BN_free(s);
        return error.OutOfMemory;
    }

    if (crypto.ECDSA_do_verify(digest.ptr, digest.len, sig, ec) == 1) return true;
    // A bad signature is an expected outcome, not a failure: don't leave it on
    // the thread's error queue for the next libcrypto caller.
    crypto.ERR_clear_error();
    return false;
}

/// The `hash_name` digest of `data`, written to `out`.
fn digestOf(data: []const u8, hash_name: []const u8, out: *[crypto.EVP_MAX_MD_SIZE]u8) ![]const u8 {
    const md = crypto.findDigest(hash_name) catch return error.OperationError;
    var len: c_uint = 0;
    if (crypto.EVP_Digest(data.ptr, data.len, out, &len, md, null) != 1) return error.OperationError;
    return out[0..len];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

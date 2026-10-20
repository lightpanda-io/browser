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

//! Octet Key Pair keys, Ed25519 (RFC 8032) and X25519 (RFC 7748): generate,
//! import and export (raw, spki and pkcs8 per RFC 8410, jwk per RFC 8037), and
//! Ed25519's sign / verify (X25519's deriveBits is in X25519.zig). The key
//! material lives as a libcrypto EVP_PKEY in `CryptoKey._vary.pkey`, as for EC
//! and RSA.

const std = @import("std");
const crypto = @import("../../../sys/libcrypto.zig");

const js = @import("../../js/js.zig");
const algorithm = @import("algorithm.zig");
const common = @import("common.zig");

const CryptoKey = @import("../CryptoKey.zig");
const Execution = js.Execution;

/// An Octet Key Pair algorithm: its name, which is also its JWK `crv`, how
/// libcrypto knows it, and the usages of each half.
pub const Curve = struct {
    name: []const u8,
    key_type: CryptoKey.Type,
    pkey_type: c_int,
    /// The size of the public key and of the private key.
    size: usize,
    private_usages: []const []const u8,
    public_usages: []const []const u8,
    /// The JWK `use` its keys are for.
    jwk_use: []const u8,
    /// Whether its JWK carries an `alg`: the algorithm's name on export, that
    /// or "EdDSA" on import. X25519's has none, and ignores one on import.
    jwk_alg: bool,
};

const curves = [_]Curve{
    .{
        .name = "Ed25519",
        .key_type = .ed25519,
        .pkey_type = crypto.EVP_PKEY_ED25519,
        .size = 32,
        .private_usages = &.{"sign"},
        .public_usages = &.{"verify"},
        .jwk_use = "sig",
        .jwk_alg = true,
    },
    .{
        .name = "X25519",
        .key_type = .x25519,
        .pkey_type = crypto.EVP_PKEY_X25519,
        .size = 32,
        .private_usages = &.{ "deriveKey", "deriveBits" },
        .public_usages = &.{},
        .jwk_use = "enc",
        .jwk_alg = false,
    },
};

/// The curve an algorithm name refers to, case-insensitively, or null.
pub fn curveOf(name: []const u8) ?*const Curve {
    for (&curves) |*curve| {
        if (std.ascii.eqlIgnoreCase(name, curve.name)) return curve;
    }
    return null;
}

/// Generates a key pair, splitting the usages between its halves (Ed25519's
/// "sign" and "verify"; X25519's "deriveKey" and "deriveBits" go to the
/// private key). Any other usage, or none for the private key, is SyntaxError.
pub fn generate(curve: *const Curve, extractable: bool, key_usages: []const []const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    for (key_usages) |usage| {
        if (!common.usageIn(curve.private_usages, usage) and !common.usageIn(curve.public_usages, usage)) {
            return error.SyntaxError;
        }
    }
    const private_mask = common.usageIntersection(curve.private_usages, key_usages);
    const public_mask = common.usageIntersection(curve.public_usages, key_usages);
    if (private_mask == 0) return error.SyntaxError;

    // libcrypto takes an Ed25519 private key as its 32-byte seed, the first
    // half of what ED25519_keypair returns.
    var public_key: [32]u8 = undefined;
    var private_key: [crypto.ED25519_PRIVATE_KEY_LEN]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_key);
    switch (curve.key_type) {
        .ed25519 => crypto.ED25519_keypair(&public_key, &private_key),
        .x25519 => crypto.X25519_keypair(&public_key, private_key[0..32]),
        // A curve added to the table without its key pair generation.
        else => return error.NotSupported,
    }

    const private_pkey = crypto.EVP_PKEY_new_raw_private_key(curve.pkey_type, null, &private_key, curve.size) orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(private_pkey);
    const public_pkey = crypto.EVP_PKEY_new_raw_public_key(curve.pkey_type, null, &public_key, public_key.len) orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(public_pkey);

    const private = try newKey(curve, private_pkey, true, extractable, private_mask, exec);
    // Public keys are always extractable.
    const public = try newKey(curve, public_pkey, false, true, public_mask, exec);
    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports a key from `spki` or `pkcs8` DER, or a `raw` public key. A
/// malformed structure (common.parseDer), a key of another algorithm, or a
/// raw key of the wrong size is DataError. JWK goes through `importJwk`. The usages were already
/// checked against the key's kind (SubtleCrypto.importKey).
pub fn import(
    curve: *const Curve,
    format: []const u8,
    data: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const pkey = blk: {
        if (std.mem.eql(u8, format, "raw")) {
            if (data.len != curve.size) return error.DataError;
            break :blk crypto.EVP_PKEY_new_raw_public_key(curve.pkey_type, null, data.ptr, data.len) orelse {
                crypto.ERR_clear_error();
                return error.DataError;
            };
        }
        break :blk try common.parseDer(format, data);
    };
    errdefer crypto.EVP_PKEY_free(pkey);

    // The DER's own algorithm identifier must be this curve's.
    if (crypto.EVP_PKEY_id(pkey) != curve.pkey_type) return error.DataError;

    return local.resolvePromise(try newKey(curve, pkey, is_private, extractable, usages_mask, exec));
}

/// Imports a key from a JSON Web Key (RFC 8037): kty "OKP", the common `use`
/// ("sig" for Ed25519, "enc" for X25519) / key_ops / ext checks, `crv` naming
/// the curve, for Ed25519 an `alg`, if any, of its name or "EdDSA", and `x`
/// (plus `d` for a private key) of the curve's size, `x` being `d`'s public
/// key. Anything else is DataError.
pub fn importJwk(
    curve: *const Curve,
    jwk: algorithm.KeyData.Jwk,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    if (!std.mem.eql(u8, jwk.kty orelse "", "OKP")) return error.DataError;
    try common.checkJwk(jwk, curve.jwk_use, usages_mask, extractable);
    if (!std.mem.eql(u8, jwk.crv orelse "", curve.name)) return error.DataError;
    if (curve.jwk_alg) {
        if (jwk.alg) |alg| {
            if (!std.mem.eql(u8, alg, curve.name) and !std.mem.eql(u8, alg, "EdDSA")) return error.DataError;
        }
    }

    const x = try common.jwkBytes(exec.local_arena, jwk.x, curve.size);
    const pkey = blk: {
        const d = jwk.d orelse {
            break :blk crypto.EVP_PKEY_new_raw_public_key(curve.pkey_type, null, x.ptr, x.len) orelse {
                crypto.ERR_clear_error();
                return error.DataError;
            };
        };
        const seed = try common.jwkBytes(exec.local_arena, d, curve.size);
        defer std.crypto.secureZero(u8, seed);
        break :blk crypto.EVP_PKEY_new_raw_private_key(curve.pkey_type, null, seed.ptr, seed.len) orelse {
            crypto.ERR_clear_error();
            return error.DataError;
        };
    };
    errdefer crypto.EVP_PKEY_free(pkey);

    // A private key's `x` must be its own public key.
    if (jwk.d != null) {
        const public = try rawPublic(pkey, exec);
        if (!std.mem.eql(u8, public, x)) return error.DataError;
    }

    return local.resolvePromise(try newKey(curve, pkey, jwk.d != null, extractable, usages_mask, exec));
}

/// Wraps `pkey` in a CryptoKey, which takes ownership of it on success only.
fn newKey(
    curve: *const Curve,
    pkey: *crypto.EVP_PKEY,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !*CryptoKey {
    return CryptoKey.init(exec, .{
        ._type = curve.key_type,
        ._kind = if (is_private) .private else .public,
        ._extractable = extractable,
        ._usages = usages_mask,
        ._key = &.{},
        ._algorithm = .{ .name = curve.name },
        ._vary = .{ .pkey = pkey },
    });
}

/// The public key's bytes: the `raw` export, and a JWK's `x`.
fn rawPublic(pkey: *const crypto.EVP_PKEY, exec: *const Execution) ![]u8 {
    var len: usize = 0;
    if (crypto.EVP_PKEY_get_raw_public_key(pkey, null, &len) != 1) return error.OperationError;
    const out = try exec.local_arena.alloc(u8, len);
    if (crypto.EVP_PKEY_get_raw_public_key(pkey, out.ptr, &len) != 1) return error.OperationError;
    return out[0..len];
}

/// The `raw` export of a public key.
pub fn exportRaw(key: *const CryptoKey, exec: *const Execution) ![]const u8 {
    return rawPublic(key.getKeyObject(), exec);
}

/// The JWK of an OKP key (RFC 8037). Members are listed in lexicographic
/// order, the order browsers return a JsonWebKey in. Ed25519's carries an
/// `alg`, its name; X25519's doesn't.
const SigningPublic = struct {
    alg: []const u8,
    crv: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "OKP",
    x: []const u8,
};

const SigningPrivate = struct {
    alg: []const u8,
    crv: []const u8,
    d: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "OKP",
    x: []const u8,
};

const AgreementPublic = struct {
    crv: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "OKP",
    x: []const u8,
};

const AgreementPrivate = struct {
    crv: []const u8,
    d: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "OKP",
    x: []const u8,
};

/// The JWK of either half of an Ed25519 or X25519 key.
pub const Jwk = union(enum) {
    signing_public: SigningPublic,
    signing_private: SigningPrivate,
    agreement_public: AgreementPublic,
    agreement_private: AgreementPrivate,
};

/// Exports a key as a JWK: `x` for either half, plus `d` for the private key.
pub fn exportJwk(key: *const CryptoKey, exec: *const Execution) !Jwk {
    const curve = curveOf(key._algorithm.name) orelse return error.OperationError;
    const pkey = key.getKeyObject();
    const x = try common.base64Encode(exec.local_arena, try rawPublic(pkey, exec));
    const key_ops = try key.getUsages(exec);
    const ext = key._extractable;

    if (key._kind == .public) {
        if (curve.jwk_alg) {
            return .{ .signing_public = .{ .alg = curve.name, .crv = curve.name, .ext = ext, .key_ops = key_ops, .x = x } };
        }
        return .{ .agreement_public = .{ .crv = curve.name, .ext = ext, .key_ops = key_ops, .x = x } };
    }
    var len: usize = 0;
    if (crypto.EVP_PKEY_get_raw_private_key(pkey, null, &len) != 1) return error.OperationError;
    const private = try exec.local_arena.alloc(u8, len);
    defer std.crypto.secureZero(u8, private);
    if (crypto.EVP_PKEY_get_raw_private_key(pkey, private.ptr, &len) != 1) return error.OperationError;
    const d = try common.base64Encode(exec.local_arena, private[0..len]);
    if (curve.jwk_alg) {
        return .{ .signing_private = .{ .alg = curve.name, .crv = curve.name, .d = d, .ext = ext, .key_ops = key_ops, .x = x } };
    }
    return .{ .agreement_private = .{ .crv = curve.name, .d = d, .ext = ext, .key_ops = key_ops, .x = x } };
}

/// Signs `data` with a private key (pure Ed25519, no prehash).
pub fn sign(key: *const CryptoKey, data: []const u8, exec: *const Execution) ![]const u8 {
    const ctx = crypto.EVP_MD_CTX_new() orelse return error.OutOfMemory;
    defer crypto.EVP_MD_CTX_free(ctx);
    if (crypto.EVP_DigestSignInit(ctx, null, null, null, key.getKeyObject()) != 1) {
        crypto.ERR_clear_error();
        return error.OperationError;
    }
    const signature = try exec.local_arena.alloc(u8, crypto.ED25519_SIGNATURE_LEN);
    var len: usize = signature.len;
    if (crypto.EVP_DigestSign(ctx, signature.ptr, &len, data.ptr, data.len) != 1) {
        crypto.ERR_clear_error();
        return error.OperationError;
    }
    return signature[0..len];
}

/// Verifies `signature` over `data` with a public key. A signature of the
/// wrong size, or one that doesn't verify, is false, not an error. So is one
/// whose public key or R (the signature's first half) is an invalid point or
/// a small-order element, as the spec's verify steps ask; libcrypto doesn't
/// check that (w3c/webcrypto#423: not every implementation does).
pub fn verify(key: *const CryptoKey, signature: []const u8, data: []const u8) !bool {
    if (signature.len != crypto.ED25519_SIGNATURE_LEN) return false;

    var public: [crypto.ED25519_PUBLIC_KEY_LEN]u8 = undefined;
    var len: usize = public.len;
    if (crypto.EVP_PKEY_get_raw_public_key(key.getKeyObject(), &public, &len) != 1) return error.OperationError;
    if (!isStrongPoint(public) or !isStrongPoint(signature[0..32].*)) return false;

    const ctx = crypto.EVP_MD_CTX_new() orelse return error.OutOfMemory;
    defer crypto.EVP_MD_CTX_free(ctx);
    if (crypto.EVP_DigestVerifyInit(ctx, null, null, null, key.getKeyObject()) != 1) {
        crypto.ERR_clear_error();
        return error.OperationError;
    }
    const valid = crypto.EVP_DigestVerify(ctx, signature.ptr, signature.len, data.ptr, data.len) == 1;
    if (!valid) crypto.ERR_clear_error();
    return valid;
}

/// Whether `encoding` decodes to an Ed25519 point that isn't of small order.
fn isStrongPoint(encoding: [32]u8) bool {
    const point = std.crypto.ecc.Edwards25519.fromBytes(encoding) catch return false;
    point.rejectLowOrder() catch return false;
    return true;
}

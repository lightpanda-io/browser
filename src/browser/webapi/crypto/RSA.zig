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

//! RSA-OAEP, RSASSA-PKCS1-v1_5 and RSA-PSS: key generation, import and export
//! (spki/pkcs8 DER and JWK), the encrypt/decrypt operations of RSA-OAEP and
//! the sign/verify operations of RSASSA-PKCS1-v1_5 and RSA-PSS. The key
//! material lives as a libcrypto EVP_PKEY in `CryptoKey._vary.pkey`. See
//! EC.zig for the asymmetric-key rationale.

const std = @import("std");

const algorithm = @import("algorithm.zig");
const common = @import("common.zig");
const crypto = @import("../../../sys/libcrypto.zig");
const js = @import("../../js/js.zig");
const CryptoKey = @import("../CryptoKey.zig");
const Execution = js.Execution;

pub fn validate(params: algorithm.Init.RsaHashedKeyGen, hash_name: []const u8, key_usages: []const []const u8) !void {
    const allowed: []const []const u8 = blk: {
        if (eql(params.name, "RSASSA-PKCS1-v1_5") or eql(params.name, "RSA-PSS")) {
            break :blk &.{ "sign", "verify" };
        }
        if (eql(params.name, "RSA-OAEP")) {
            break :blk &.{ "encrypt", "decrypt", "wrapKey", "unwrapKey" };
        }
        return error.NotSupported;
    };

    if (canonicalHash(hash_name) == null) {
        return error.NotSupported;
    }

    for (key_usages) |usage| {
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, usage)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            return error.SyntaxError;
        }
    }

    if (!isValidPublicExponent(params.publicExponent.values)) {
        return error.OperationError;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

// WebCrypto only mandates rejection on key-generation failure, but in
// practice browsers accept the standard exponents 3 and 65537 and reject
// the rest. Match that.
fn isValidPublicExponent(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = 0;
    while (i + 1 < bytes.len and bytes[i] == 0) : (i += 1) {}
    const trimmed = bytes[i..];
    if (trimmed.len == 1 and trimmed[0] == 3) return true;
    if (trimmed.len == 3 and trimmed[0] == 0x01 and trimmed[1] == 0x00 and trimmed[2] == 0x01) return true;
    return false;
}

/// What sets the RSA algorithms implemented here apart: the usages of each
/// half of a key pair and the JWK members that describe their keys.
pub const Scheme = struct {
    name: []const u8,
    private_usages: []const []const u8,
    public_usages: []const []const u8,
    /// The JWK `use` of the keys.
    jwk_use: []const u8,
    /// The JWK `alg` for each of `hashes`: the values of JWA, sections 3.1 and
    /// 4.1, and WebCrypto's "RS1" and "PS1" for the signatures with SHA-1.
    jwk_algs: [hashes.len][]const u8,
};

const schemes = [_]Scheme{
    .{
        .name = "RSA-OAEP",
        .private_usages = &.{ "decrypt", "unwrapKey" },
        .public_usages = &.{ "encrypt", "wrapKey" },
        .jwk_use = "enc",
        .jwk_algs = .{ "RSA-OAEP", "RSA-OAEP-256", "RSA-OAEP-384", "RSA-OAEP-512" },
    },
    .{
        .name = "RSASSA-PKCS1-v1_5",
        .private_usages = &.{"sign"},
        .public_usages = &.{"verify"},
        .jwk_use = "sig",
        .jwk_algs = .{ "RS1", "RS256", "RS384", "RS512" },
    },
    .{
        .name = "RSA-PSS",
        .private_usages = &.{"sign"},
        .public_usages = &.{"verify"},
        .jwk_use = "sig",
        .jwk_algs = .{ "PS1", "PS256", "PS384", "PS512" },
    },
};

/// The scheme of an RSA algorithm name (case-insensitive), or null if it isn't
/// one implemented here.
pub fn scheme(name: []const u8) ?*const Scheme {
    for (&schemes) |*s| {
        if (eql(name, s.name)) return s;
    }
    return null;
}

const hashes = common.hashes;
const canonicalHash = common.canonicalHash;

/// The JWK `alg` of `s` for a canonical hash name.
fn jwkAlgOfHash(s: *const Scheme, hash: []const u8) ?[]const u8 {
    for (hashes, s.jwk_algs) |h, alg| {
        if (std.mem.eql(u8, h, hash)) return alg;
    }
    return null;
}

/// The canonical hash for a JWK `alg` of `s`. The spec matches `alg`
/// case-sensitively.
fn hashOfJwkAlg(s: *const Scheme, alg: []const u8) ?[]const u8 {
    for (hashes, s.jwk_algs) |hash, a| {
        if (std.mem.eql(u8, a, alg)) return hash;
    }
    return null;
}

const max_modulus_length = 4096;

/// Generates an RSA key pair of `modulusLength` bits with the given public
/// exponent. Mirrors EC.generate: each key keeps the EVP_PKEY of its half, and
/// the requested usages are split across the pair (validate() rejected illegal
/// ones).
pub fn generate(
    params: algorithm.Init.RsaHashedKeyGen,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    // Normalization: the algorithm name, then the dictionary's members, then
    // the hash (validate). The usages come after.
    const s = scheme(params.name) orelse return error.NotSupported;
    const requested_bits = params.modulusLength.value;
    const requested_hash = try params.hash.name(local);
    try validate(params, requested_hash, key_usages);

    // Generation runs on the main thread and can't be interrupted, and its cost
    // grows steeply with the size: 8192 bits takes seconds, 16384 (BoringSSL's
    // ceiling) tens of seconds, several times that on a vCPU. Pages generate
    // 2048 or 4096 in practice. Chrome allows 16384 but generates off-thread.
    if (requested_bits > max_modulus_length) return error.OperationError;

    const hash_name = canonicalHash(requested_hash).?;
    const private_mask = common.usageIntersection(s.private_usages, key_usages);
    const public_mask = common.usageIntersection(s.public_usages, key_usages);
    // The private key must end up with at least one usage.
    if (private_mask == 0) return error.SyntaxError;

    // Public exponent as a big-endian BIGNUM (e.g. 65537 == {0x01, 0x00, 0x01}).
    const e = crypto.BN_new() orelse return error.OutOfMemory;
    defer crypto.BN_free(e);
    const exp = params.publicExponent.values;
    if (crypto.BN_bin2bn(exp.ptr, exp.len, e) == null) return error.OperationError;

    const rsa = crypto.RSA_new() orelse return error.OutOfMemory;
    defer crypto.RSA_free(rsa);
    if (crypto.RSA_generate_key_ex(rsa, @intCast(requested_bits), e, null) != 1) {
        return error.OperationError;
    }

    const private_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(private_pkey);
    if (crypto.EVP_PKEY_set1_RSA(private_pkey, rsa) != 1) return error.OutOfMemory;

    // An independent public-only key for the other half of the pair, so freeing
    // one CryptoKey never touches the other's EVP_PKEY.
    const rsa_pub = crypto.RSAPublicKey_dup(rsa) orelse return error.OutOfMemory;
    defer crypto.RSA_free(rsa_pub);
    const public_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(public_pkey);
    if (crypto.EVP_PKEY_set1_RSA(public_pkey, rsa_pub) != 1) return error.OutOfMemory;

    const modulus_length: u32 = @intCast(crypto.EVP_PKEY_bits(private_pkey));
    const public_exponent = try exponentBytes(private_pkey, exec);

    const private = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .private,
        ._extractable = extractable,
        ._usages = private_mask,
        ._key = &.{},
        ._algorithm = .{ .name = s.name, .hash = hash_name, .modulus_length = modulus_length, .public_exponent = public_exponent },
        ._vary = .{ .pkey = private_pkey },
    });

    const public = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .public,
        // Public keys are always extractable.
        ._extractable = true,
        ._usages = public_mask,
        ._key = &.{},
        ._algorithm = .{ .name = s.name, .hash = hash_name, .modulus_length = modulus_length, .public_exponent = public_exponent },
        ._vary = .{ .pkey = public_pkey },
    });

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports an RSA key of scheme `s` from DER: `spki` (public) or `pkcs8`
/// (private). A malformed structure is DataError (common.parseDer).
/// `hash_name` is the digest of the OAEP padding or of the signature, kept on
/// the key. JWK goes through `importJwk`.
pub fn import(
    s: *const Scheme,
    format: []const u8,
    der: []const u8,
    hash_name: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    // Reject an unsupported digest at import time, rather than letting it
    // surface only on the first operation.
    const hash = canonicalHash(hash_name) orelse return error.NotSupported;

    // "raw" isn't a format RSA keys have: NotSupported from parseDer.
    const pkey = try common.parseDer(format, der);
    errdefer crypto.EVP_PKEY_free(pkey);

    if (crypto.EVP_PKEY_id(pkey) != crypto.EVP_PKEY_RSA) return error.DataError;

    return local.resolvePromise(try newKey(s, pkey, hash, is_private, extractable, usages_mask, exec));
}

/// Imports an RSA key of scheme `s` from a JSON Web Key: `n` and `e` for a
/// public key, plus `d`, `p`, `q`, `dp`, `dq` and `qi` for a private one (the
/// presence of `d` decides, as in SubtleCrypto.importKind, which already
/// validated the usages against it). Follows the "import key" steps of
/// RSA-OAEP, RSASSA-PKCS1-v1_5 and RSA-PSS: a JWK that doesn't fit the
/// requested key, or describes an invalid one, is DataError.
pub fn importJwk(
    s: *const Scheme,
    jwk: algorithm.KeyData.Jwk,
    hash_name: []const u8,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const hash = canonicalHash(hash_name) orelse return error.NotSupported;

    if (!std.mem.eql(u8, jwk.kty orelse "", "RSA")) return error.DataError;
    try common.checkJwk(jwk, s.jwk_use, usages_mask, extractable);
    // `alg` is optional; when present, it must name the requested hash.
    if (jwk.alg) |alg| {
        const alg_hash = hashOfJwkAlg(s, alg) orelse return error.DataError;
        if (!std.mem.eql(u8, alg_hash, hash)) return error.DataError;
    }

    const rsa = try rsaFromJwk(jwk, exec);
    defer crypto.RSA_free(rsa);
    const pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(pkey);
    if (crypto.EVP_PKEY_set1_RSA(pkey, rsa) != 1) return error.OutOfMemory;

    return local.resolvePromise(try newKey(s, pkey, hash, jwk.d != null, extractable, usages_mask, exec));
}

/// The RSA key described by a JWK (JWA, section 6.3). A private key needs all
/// of the CRT members; libcrypto rejects members that don't make a valid key,
/// such as the extra primes of `oth`, which this two-prime import ignores.
fn rsaFromJwk(jwk: algorithm.KeyData.Jwk, exec: *const Execution) !*crypto.RSA {
    const members = [_]?[]const u8{ jwk.n, jwk.e, jwk.d, jwk.p, jwk.q, jwk.dp, jwk.dq, jwk.qi };
    const needed: usize = if (jwk.d == null) 2 else members.len;

    var nums: [members.len]*crypto.BIGNUM = undefined;
    var count: usize = 0;
    defer for (nums[0..count]) |num| crypto.BN_free(num);
    for (members[0..needed]) |member| {
        nums[count] = try jwkBigNum(member, exec);
        count += 1;
    }

    if (jwk.d == null) {
        return crypto.RSA_new_public_key(nums[0], nums[1]) orelse error.DataError;
    }
    return crypto.RSA_new_private_key(nums[0], nums[1], nums[2], nums[3], nums[4], nums[5], nums[6], nums[7]) orelse error.DataError;
}

/// A JWK Base64urlUInt member as a BIGNUM. A missing or empty member, or one
/// with a leading zero octet (JWA, section 2: it must use the minimum number of
/// octets), is DataError.
fn jwkBigNum(member: ?[]const u8, exec: *const Execution) !*crypto.BIGNUM {
    const bytes = try common.base64Decode(exec.local_arena, member orelse return error.DataError);
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == 0)) return error.DataError;
    return crypto.BN_bin2bn(bytes.ptr, bytes.len, null) orelse error.OutOfMemory;
}

/// Wraps an RSA `pkey` in a CryptoKey of scheme `s`. The key takes ownership
/// of `pkey` only on success.
fn newKey(
    s: *const Scheme,
    pkey: *crypto.EVP_PKEY,
    hash: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !*CryptoKey {
    return CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = if (is_private) .private else .public,
        ._extractable = extractable,
        ._usages = usages_mask,
        ._key = &.{},
        ._algorithm = .{
            .name = s.name,
            .hash = hash,
            .modulus_length = @intCast(crypto.EVP_PKEY_bits(pkey)),
            .public_exponent = try exponentBytes(pkey, exec),
        },
        ._vary = .{ .pkey = pkey },
    });
}

/// The JWK of an RSA key (JWA, section 6.3). Members are listed in
/// lexicographic order, the order browsers return a JsonWebKey in.
const JwkPublic = struct {
    alg: []const u8,
    e: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "RSA",
    n: []const u8,
};

const JwkPrivate = struct {
    alg: []const u8,
    d: []const u8,
    dp: []const u8,
    dq: []const u8,
    e: []const u8,
    ext: bool,
    key_ops: []const []const u8,
    kty: []const u8 = "RSA",
    n: []const u8,
    p: []const u8,
    q: []const u8,
    qi: []const u8,
};

/// The JWK of either half of an RSA key.
pub const Jwk = union(enum) {
    public: JwkPublic,
    private: JwkPrivate,
};

/// Exports an RSA key as a JWK: the public members for either half, plus the
/// private members (with the CRT parameters) for the private key.
pub fn exportJwk(key: *const CryptoKey, exec: *const Execution) !Jwk {
    const rsa = crypto.EVP_PKEY_get0_RSA(key.getKeyObject()) orelse return error.OperationError;
    const s = scheme(key._algorithm.name) orelse return error.OperationError;
    const alg = jwkAlgOfHash(s, key._algorithm.hash orelse "") orelse return error.OperationError;
    const n = try jwkMember(crypto.RSA_get0_n(rsa), exec);
    const e = try jwkMember(crypto.RSA_get0_e(rsa), exec);
    const key_ops = try key.getUsages(exec);

    if (key._kind == .public) {
        return .{ .public = .{ .alg = alg, .e = e, .ext = key._extractable, .key_ops = key_ops, .n = n } };
    }
    return .{ .private = .{
        .alg = alg,
        .d = try jwkMember(crypto.RSA_get0_d(rsa), exec),
        .dp = try jwkMember(crypto.RSA_get0_dmp1(rsa), exec),
        .dq = try jwkMember(crypto.RSA_get0_dmq1(rsa), exec),
        .e = e,
        .ext = key._extractable,
        .key_ops = key_ops,
        .n = n,
        .p = try jwkMember(crypto.RSA_get0_p(rsa), exec),
        .q = try jwkMember(crypto.RSA_get0_q(rsa), exec),
        .qi = try jwkMember(crypto.RSA_get0_iqmp(rsa), exec),
    } };
}

/// A key component as a JWK Base64urlUInt member.
fn jwkMember(bn: ?*const crypto.BIGNUM, exec: *const Execution) ![]const u8 {
    return common.base64Encode(exec.local_arena, try bnBytes(bn, exec));
}

/// The public exponent of an RSA EVP_PKEY, big-endian, in the local arena.
fn exponentBytes(pkey: *const crypto.EVP_PKEY, exec: *const Execution) ![]const u8 {
    const rsa = crypto.EVP_PKEY_get0_RSA(pkey) orelse return error.OperationError;
    return bnBytes(crypto.RSA_get0_e(rsa), exec);
}

/// A BIGNUM as big-endian bytes (the minimum number of them), in the local arena.
fn bnBytes(bn: ?*const crypto.BIGNUM, exec: *const Execution) ![]const u8 {
    const num = bn orelse return error.OperationError;
    const out = try exec.local_arena.alloc(u8, crypto.BN_num_bytes(num));
    return out[0..crypto.BN_bn2bin(num, out.ptr)];
}

/// RSA-OAEP encrypt/decrypt. `encrypting` selects the init/op pair; the
/// padding, OAEP digest (the hash stored on the key), MGF1 digest, label and
/// the two-call output sizing are identical for both directions. `usage` is the
/// usage bit the key needs: encrypt/decrypt, or wrapKey/unwrapKey when wrapping
/// a key.
pub fn crypt(
    key: *const CryptoKey,
    data: []const u8,
    label: []const u8,
    encrypting: bool,
    usage: u8,
    exec: *const Execution,
) ![]const u8 {
    // The key must be an RSA-OAEP key with the matching usage.
    if (key._type != .rsa or !std.mem.eql(u8, key._algorithm.name, "RSA-OAEP")) return error.InvalidAccessError;
    if (key._usages & usage == 0) return error.InvalidAccessError;

    const hash_name = key._algorithm.hash orelse return error.OperationError;
    const md = crypto.findDigest(hash_name) catch return error.OperationError;

    const ctx = crypto.EVP_PKEY_CTX_new(key.getKeyObject(), null) orelse return error.OperationError;
    defer crypto.EVP_PKEY_CTX_free(ctx);

    const init_ok = if (encrypting) crypto.EVP_PKEY_encrypt_init(ctx) else crypto.EVP_PKEY_decrypt_init(ctx);
    if (init_ok != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_padding(ctx, crypto.RSA_PKCS1_OAEP_PADDING) != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_oaep_md(ctx, md) != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, md) != 1) return error.OperationError;
    if (label.len > 0) {
        // The context takes ownership of the copy, but only on success.
        const copy: [*]u8 = @ptrCast(crypto.OPENSSL_malloc(label.len) orelse return error.OutOfMemory);
        @memcpy(copy[0..label.len], label);
        if (crypto.EVP_PKEY_CTX_set0_rsa_oaep_label(ctx, copy, label.len) != 1) {
            crypto.OPENSSL_free(copy);
            return error.OperationError;
        }
    }

    // First call (null output) reports the size; the second writes the buffer.
    var out_len: usize = 0;
    if (encrypting) {
        if (crypto.EVP_PKEY_encrypt(ctx, null, &out_len, data.ptr, data.len) != 1) return error.OperationError;
    } else {
        if (crypto.EVP_PKEY_decrypt(ctx, null, &out_len, data.ptr, data.len) != 1) return error.OperationError;
    }
    const out = try exec.local_arena.alloc(u8, out_len);
    if (encrypting) {
        if (crypto.EVP_PKEY_encrypt(ctx, out.ptr, &out_len, data.ptr, data.len) != 1) return error.OperationError;
    } else {
        if (crypto.EVP_PKEY_decrypt(ctx, out.ptr, &out_len, data.ptr, data.len) != 1) return error.OperationError;
    }
    return out[0..out_len];
}

/// RSASSA-PKCS1-v1_5 or RSA-PSS signature generation (RFC 8017, sections
/// 8.2.1 and 8.1.1) of `data` with the key's hash. `salt_length` is RSA-PSS's,
/// in bytes. SubtleCrypto.sign checked the algorithm and the sign usage; only
/// a private key signs.
pub fn sign(key: *const CryptoKey, data: []const u8, salt_length: ?u32, exec: *const Execution) ![]const u8 {
    if (key._kind != .private) return error.InvalidAccessError;

    const ctx = try digestContext(key, false, salt_length);
    defer crypto.EVP_MD_CTX_free(ctx);

    // First call (null output) reports the size; the second writes the buffer.
    var sig_len: usize = 0;
    if (crypto.EVP_DigestSign(ctx, null, &sig_len, data.ptr, data.len) != 1) return error.OperationError;
    const out = try exec.local_arena.alloc(u8, sig_len);
    if (crypto.EVP_DigestSign(ctx, out.ptr, &sig_len, data.ptr, data.len) != 1) return error.OperationError;
    return out[0..sig_len];
}

/// RSASSA-PKCS1-v1_5 or RSA-PSS signature verification (RFC 8017, sections
/// 8.2.2 and 8.1.2) of `signature` over `data` with the key's hash, and
/// RSA-PSS's `salt_length`. SubtleCrypto.verify checked the algorithm and the
/// verify usage; only a public key verifies. A signature that doesn't match,
/// whatever its length or salt, is false rather than an error.
pub fn verify(key: *const CryptoKey, signature: []const u8, data: []const u8, salt_length: ?u32) !bool {
    if (key._kind != .public) return error.InvalidAccessError;

    const ctx = try digestContext(key, true, salt_length);
    defer crypto.EVP_MD_CTX_free(ctx);

    if (crypto.EVP_DigestVerify(ctx, signature.ptr, signature.len, data.ptr, data.len) == 1) return true;
    // A bad signature is an expected outcome, not a failure: don't leave it on
    // the thread's error queue for the next libcrypto caller.
    crypto.ERR_clear_error();
    return false;
}

/// A digest context set up to sign or verify with `key`: its hash, and the
/// padding of its algorithm (PKCS #1 v1.5, or PSS with MGF1 over the same hash
/// and `salt_length`). Free it with EVP_MD_CTX_free.
fn digestContext(key: *const CryptoKey, verifying: bool, salt_length: ?u32) !*crypto.EVP_MD_CTX {
    const hash_name = key._algorithm.hash orelse return error.OperationError;
    const md = crypto.findDigest(hash_name) catch return error.OperationError;

    const ctx = crypto.EVP_MD_CTX_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_MD_CTX_free(ctx);
    // The key context belongs to `ctx`.
    var pctx: ?*crypto.EVP_PKEY_CTX = null;
    const init_ok = if (verifying)
        crypto.EVP_DigestVerifyInit(ctx, &pctx, md, null, key.getKeyObject())
    else
        crypto.EVP_DigestSignInit(ctx, &pctx, md, null, key.getKeyObject());
    if (init_ok != 1) return error.OperationError;

    if (!std.mem.eql(u8, key._algorithm.name, "RSA-PSS")) {
        if (crypto.EVP_PKEY_CTX_set_rsa_padding(pctx, crypto.RSA_PKCS1_PADDING) != 1) return error.OperationError;
        return ctx;
    }
    // Negative lengths are libcrypto's special values (the digest's length,
    // the maximum), so a length past c_int is capped instead: it's longer than
    // any key allows, and signing or verifying with it fails as it should.
    const salt: c_int = @intCast(@min(salt_length orelse return error.OperationError, std.math.maxInt(c_int)));
    if (crypto.EVP_PKEY_CTX_set_rsa_padding(pctx, crypto.RSA_PKCS1_PSS_PADDING) != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_mgf1_md(pctx, md) != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, salt) != 1) return error.OperationError;
    return ctx;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

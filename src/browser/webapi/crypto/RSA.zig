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

//! RSA-OAEP: key generation, import and export (spki/pkcs8 DER and JWK), and
//! the encrypt/decrypt operations. The key material lives as a libcrypto
//! EVP_PKEY in `CryptoKey._vary.pkey`. See EC.zig for the asymmetric-key
//! rationale.

const std = @import("std");

const algorithm = @import("algorithm.zig");
const common = @import("common.zig");
const crypto = @import("../../../sys/libcrypto.zig");
const js = @import("../../js/js.zig");
const CryptoKey = @import("../CryptoKey.zig");
const Execution = js.Execution;

pub fn validate(params: algorithm.Init.RsaHashedKeyGen, key_usages: []const []const u8) !void {
    const allowed: []const []const u8 = blk: {
        if (eql(params.name, "RSASSA-PKCS1-v1_5") or eql(params.name, "RSA-PSS")) {
            break :blk &.{ "sign", "verify" };
        }
        if (eql(params.name, "RSA-OAEP")) {
            break :blk &.{ "encrypt", "decrypt", "wrapKey", "unwrapKey" };
        }
        return error.NotSupported;
    };

    const hash_name = switch (params.hash) {
        .string => |s| s,
        .object => |o| o.name,
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

/// The registered name (case-insensitive), or null if not an RSA-OAEP algorithm.
pub fn canonicalName(name: []const u8) ?[]const u8 {
    if (eql(name, "RSA-OAEP")) return "RSA-OAEP";
    return null;
}

/// The registered hash name (case-insensitive), or null if not a supported
/// hash. Stored on the key, so `.algorithm.hash.name` reports it and
/// `findDigest` (which is case-sensitive) can look it up.
pub fn canonicalHash(name: []const u8) ?[]const u8 {
    inline for ([_][]const u8{ "SHA-1", "SHA-256", "SHA-384", "SHA-512" }) |canonical| {
        if (eql(name, canonical)) return canonical;
    }
    return null;
}

/// The JWK `alg` of each OAEP hash (JWA, section 4.3).
const jwk_algs = [_]struct { hash: []const u8, alg: []const u8 }{
    .{ .hash = "SHA-1", .alg = "RSA-OAEP" },
    .{ .hash = "SHA-256", .alg = "RSA-OAEP-256" },
    .{ .hash = "SHA-384", .alg = "RSA-OAEP-384" },
    .{ .hash = "SHA-512", .alg = "RSA-OAEP-512" },
};

/// The JWK `alg` for a canonical hash name.
fn jwkAlgOfHash(hash: []const u8) ?[]const u8 {
    for (jwk_algs) |entry| {
        if (std.mem.eql(u8, entry.hash, hash)) return entry.alg;
    }
    return null;
}

/// The canonical hash for a JWK `alg`. The spec matches `alg` case-sensitively.
fn hashOfJwkAlg(alg: []const u8) ?[]const u8 {
    for (jwk_algs) |entry| {
        if (std.mem.eql(u8, entry.alg, alg)) return entry.hash;
    }
    return null;
}

const max_modulus_length = 4096;

const private_usages: []const []const u8 = &.{ "decrypt", "unwrapKey" };
const public_usages: []const []const u8 = &.{ "encrypt", "wrapKey" };

/// Generates an RSA-OAEP key pair of `modulusLength` bits with the given public
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
    try validate(params, key_usages);

    // validate() also accepts RSASSA-PKCS1-v1_5 and RSA-PSS (so their parameter
    // errors are reported correctly), but only RSA-OAEP generation is implemented.
    if (!eql(params.name, "RSA-OAEP")) return error.NotSupported;

    // Generation runs on the main thread and can't be interrupted, and its cost
    // grows steeply with the size: 8192 bits takes seconds, 16384 (BoringSSL's
    // ceiling) tens of seconds, several times that on a vCPU. Pages generate
    // 2048 or 4096 in practice. Chrome allows 16384 but generates off-thread.
    if (params.modulusLength > max_modulus_length) return error.OperationError;

    const hash_name = canonicalHash(switch (params.hash) {
        .string => |s| s,
        .object => |o| o.name,
    }).?;
    const private_mask = maskOf(private_usages, key_usages);
    const public_mask = maskOf(public_usages, key_usages);
    // The private key must end up with at least one usage.
    if (private_mask == 0) return error.SyntaxError;

    // Public exponent as a big-endian BIGNUM (e.g. 65537 == {0x01, 0x00, 0x01}).
    const e = crypto.BN_new() orelse return error.OutOfMemory;
    defer crypto.BN_free(e);
    const exp = params.publicExponent.values;
    if (crypto.BN_bin2bn(exp.ptr, exp.len, e) == null) return error.OperationError;

    const rsa = crypto.RSA_new() orelse return error.OutOfMemory;
    defer crypto.RSA_free(rsa);
    if (crypto.RSA_generate_key_ex(rsa, @intCast(params.modulusLength), e, null) != 1) {
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
        ._algorithm = .{ .name = "RSA-OAEP", .hash = hash_name, .modulus_length = modulus_length, .public_exponent = public_exponent },
        ._vary = .{ .pkey = private_pkey },
    });

    const public = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .public,
        // Public keys are always extractable.
        ._extractable = true,
        ._usages = public_mask,
        ._key = &.{},
        ._algorithm = .{ .name = "RSA-OAEP", .hash = hash_name, .modulus_length = modulus_length, .public_exponent = public_exponent },
        ._vary = .{ .pkey = public_pkey },
    });

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports an RSA-OAEP key from DER: `spki` (public) or `pkcs8` (private).
/// libcrypto parses the DER, so a malformed structure is DataError. `hash_name`
/// is the OAEP digest, kept for encrypt. JWK goes through `importJwk`.
pub fn import(
    format: []const u8,
    der: []const u8,
    hash_name: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    // Reject an unsupported OAEP digest at import time, rather than letting it
    // surface only on the first encrypt/decrypt.
    const hash = canonicalHash(hash_name) orelse return error.NotSupported;

    var ptr: [*c]const u8 = der.ptr;
    const pkey: *crypto.EVP_PKEY = blk: {
        if (std.mem.eql(u8, format, "spki")) {
            break :blk crypto.d2i_PUBKEY(null, &ptr, @intCast(der.len)) orelse return error.DataError;
        }
        if (std.mem.eql(u8, format, "pkcs8")) {
            break :blk crypto.d2i_AutoPrivateKey(null, &ptr, @intCast(der.len)) orelse return error.DataError;
        }
        // "raw" isn't a format RSA keys have.
        return error.NotSupported;
    };
    errdefer crypto.EVP_PKEY_free(pkey);

    if (crypto.EVP_PKEY_id(pkey) != crypto.EVP_PKEY_RSA) return error.DataError;

    return local.resolvePromise(try newKey(pkey, hash, is_private, extractable, usages_mask, exec));
}

/// Imports an RSA-OAEP key from a JSON Web Key: `n` and `e` for a public key,
/// plus `d`, `p`, `q`, `dp`, `dq` and `qi` for a private one (the presence of
/// `d` decides, as in SubtleCrypto.importKind, which already validated the
/// usages against it). Follows the "import key" steps of RSA-OAEP: a JWK that
/// doesn't fit the requested key, or describes an invalid one, is DataError.
pub fn importJwk(
    jwk: algorithm.KeyData.Jwk,
    hash_name: []const u8,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const hash = canonicalHash(hash_name) orelse return error.NotSupported;

    if (!std.mem.eql(u8, jwk.kty orelse "", "RSA")) return error.DataError;
    if (jwk.use) |use| {
        if (usages_mask != 0 and !std.mem.eql(u8, use, "enc")) return error.DataError;
    }
    if (jwk.key_ops) |key_ops| try checkKeyOps(key_ops, usages_mask);
    if (jwk.ext) |ext| {
        if (!ext and extractable) return error.DataError;
    }
    // `alg` is optional; when present, it must name the requested hash.
    if (jwk.alg) |alg| {
        const alg_hash = hashOfJwkAlg(alg) orelse return error.DataError;
        if (!std.mem.eql(u8, alg_hash, hash)) return error.DataError;
    }

    const rsa = try rsaFromJwk(jwk, exec);
    defer crypto.RSA_free(rsa);
    const pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(pkey);
    if (crypto.EVP_PKEY_set1_RSA(pkey, rsa) != 1) return error.OutOfMemory;

    return local.resolvePromise(try newKey(pkey, hash, jwk.d != null, extractable, usages_mask, exec));
}

/// A JWK `key_ops` must hold every requested usage, and no value twice
/// (RFC 7517, section 4.3). Values that aren't usages are allowed.
fn checkKeyOps(key_ops: []const []const u8, usages_mask: u8) !void {
    var listed: u8 = 0;
    for (key_ops, 0..) |op, i| {
        for (key_ops[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, op)) return error.DataError;
        }
        if (common.usageBit(op)) |bit| listed |= bit;
    }
    if (usages_mask & ~listed != 0) return error.DataError;
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

/// Wraps an RSA `pkey` in a CryptoKey. The key takes ownership of `pkey` only on
/// success.
fn newKey(
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
            .name = "RSA-OAEP",
            .hash = hash,
            .modulus_length = @intCast(crypto.EVP_PKEY_bits(pkey)),
            .public_exponent = try exponentBytes(pkey, exec),
        },
        ._vary = .{ .pkey = pkey },
    });
}

/// Exports an RSA key as DER: `spki` for a public key, `pkcs8` for a private
/// one. Asking for the other half's format is InvalidAccessError.
pub fn exportDer(format: []const u8, key: *const CryptoKey, exec: *const Execution) ![]const u8 {
    const pkey = key.getKeyObject();

    var out: [*c]u8 = null;
    const len = blk: {
        if (std.mem.eql(u8, format, "spki")) {
            if (key._kind != .public) return error.InvalidAccessError;
            break :blk crypto.i2d_PUBKEY(pkey, &out);
        }
        if (key._kind != .private) return error.InvalidAccessError;
        const info = crypto.EVP_PKEY2PKCS8(pkey) orelse return error.OperationError;
        defer crypto.PKCS8_PRIV_KEY_INFO_free(info);
        break :blk crypto.i2d_PKCS8_PRIV_KEY_INFO(info, &out);
    };
    defer crypto.OPENSSL_free(out);
    if (len <= 0) return error.OperationError;

    return exec.local_arena.dupe(u8, out[0..@intCast(len)]);
}

/// The JWK of an RSA-OAEP key (JWA, section 6.3). Members are listed in
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

/// Exports an RSA-OAEP key as a JWK object: the public members for either half,
/// plus the private members (with the CRT parameters) for the private key.
pub fn exportJwk(key: *const CryptoKey, exec: *const Execution) !js.Value {
    const local = exec.js.local.?;
    const rsa = crypto.EVP_PKEY_get0_RSA(key.getKeyObject()) orelse return error.OperationError;
    const alg = jwkAlgOfHash(key._algorithm.hash orelse "") orelse return error.OperationError;
    const n = try jwkMember(crypto.RSA_get0_n(rsa), exec);
    const e = try jwkMember(crypto.RSA_get0_e(rsa), exec);
    const key_ops = try key.getUsages(exec);

    if (key._kind == .public) {
        return local.zigValueToJs(JwkPublic{ .alg = alg, .e = e, .ext = key._extractable, .key_ops = key_ops, .n = n }, .{});
    }
    return local.zigValueToJs(JwkPrivate{
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
    }, .{});
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
    if (key._type != .rsa) return error.InvalidAccessError;
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

/// The usage bitmask of those `usages` that belong to `set`.
fn maskOf(set: []const []const u8, usages: []const []const u8) u8 {
    var mask: u8 = 0;
    for (usages) |u| {
        for (set) |s| {
            if (std.mem.eql(u8, s, u)) {
                mask |= common.usageBit(u).?;
                break;
            }
        }
    }
    return mask;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

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

//! RSA-OAEP: key generation, import (spki/pkcs8 via DER), and the
//! encrypt/decrypt operations. The key material lives as a libcrypto EVP_PKEY
//! in `CryptoKey._vary.pkey`. See EC.zig for the asymmetric-key rationale.

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
    if (!eql(hash_name, "SHA-1") and
        !eql(hash_name, "SHA-256") and
        !eql(hash_name, "SHA-384") and
        !eql(hash_name, "SHA-512"))
    {
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

/// The (private, public) usages legal for an RSA-OAEP key pair.
fn usageSets() struct { private: []const []const u8, public: []const []const u8 } {
    return .{ .private = &.{ "decrypt", "unwrapKey" }, .public = &.{ "encrypt", "wrapKey" } };
}

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

    // modulusLength must fit the c_int BoringSSL's generator takes; reject an
    // absurd size here instead of trapping on the @intCast below.
    if (params.modulusLength > std.math.maxInt(c_int)) return error.OperationError;

    const hash_name = switch (params.hash) {
        .string => |s| s,
        .object => |o| o.name,
    };
    const sets = usageSets();
    const private_mask = maskOf(sets.private, key_usages);
    const public_mask = maskOf(sets.public, key_usages);

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

    const private = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .private,
        ._extractable = extractable,
        ._usages = private_mask,
        ._key = &.{},
        ._algorithm = .{ .name = "RSA-OAEP", .hash = hash_name, .modulus_length = modulus_length },
        ._vary = .{ .pkey = private_pkey },
    });

    const public = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .public,
        // Public keys are always extractable.
        ._extractable = true,
        ._usages = public_mask,
        ._key = &.{},
        ._algorithm = .{ .name = "RSA-OAEP", .hash = hash_name, .modulus_length = modulus_length },
        ._vary = .{ .pkey = public_pkey },
    });

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports an RSA-OAEP key from DER: `spki` (public) or `pkcs8` (private).
/// jwk/raw aren't handled yet. libcrypto parses the DER, so a malformed
/// structure is DataError. `hash_name` is the OAEP digest, kept for encrypt.
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

    // Reject an unsupported OAEP digest at import time (findDigest knows the set),
    // rather than letting it surface only on the first encrypt/decrypt.
    _ = crypto.findDigest(hash_name) catch return error.NotSupported;

    var ptr: [*c]const u8 = der.ptr;
    const pkey: *crypto.EVP_PKEY = blk: {
        if (std.mem.eql(u8, format, "spki")) {
            break :blk crypto.d2i_PUBKEY(null, &ptr, @intCast(der.len)) orelse return error.DataError;
        }
        if (std.mem.eql(u8, format, "pkcs8")) {
            break :blk crypto.d2i_AutoPrivateKey(null, &ptr, @intCast(der.len)) orelse return error.DataError;
        }
        // jwk / raw not implemented yet.
        return error.NotSupported;
    };
    errdefer crypto.EVP_PKEY_free(pkey);

    if (crypto.EVP_PKEY_id(pkey) != crypto.EVP_PKEY_RSA) return error.DataError;

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = if (is_private) .private else .public,
        ._extractable = extractable,
        ._usages = usages_mask,
        ._key = &.{},
        ._algorithm = .{ .name = "RSA-OAEP", .hash = hash_name, .modulus_length = @intCast(crypto.EVP_PKEY_bits(pkey)) },
        ._vary = .{ .pkey = pkey },
    });
    return local.resolvePromise(crypto_key);
}

/// Encrypts `data` with the public key (RSA-OAEP).
pub fn encrypt(key: *const CryptoKey, data: []const u8, exec: *const Execution) ![]const u8 {
    return crypt(key, data, true, exec);
}

/// Decrypts `data` with the private key (RSA-OAEP).
pub fn decrypt(key: *const CryptoKey, data: []const u8, exec: *const Execution) ![]const u8 {
    return crypt(key, data, false, exec);
}

/// Shared RSA-OAEP transform. `encrypting` selects the init/op pair; the
/// padding, OAEP digest (the hash stored on the key), MGF1 digest and the
/// two-call output sizing are identical for both directions.
fn crypt(key: *const CryptoKey, data: []const u8, encrypting: bool, exec: *const Execution) ![]const u8 {
    const hash_name = key._algorithm.hash orelse return error.OperationError;
    const md = crypto.findDigest(hash_name) catch return error.OperationError;

    const ctx = crypto.EVP_PKEY_CTX_new(key.getKeyObject(), null) orelse return error.OperationError;
    defer crypto.EVP_PKEY_CTX_free(ctx);

    const init_ok = if (encrypting) crypto.EVP_PKEY_encrypt_init(ctx) else crypto.EVP_PKEY_decrypt_init(ctx);
    if (init_ok != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_padding(ctx, crypto.RSA_PKCS1_OAEP_PADDING) != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_oaep_md(ctx, md) != 1) return error.OperationError;
    if (crypto.EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, md) != 1) return error.OperationError;

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

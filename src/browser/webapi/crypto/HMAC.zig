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

//! Interprets `CryptoKey` for HMAC.

const std = @import("std");
const lp = @import("lightpanda");
const crypto = @import("../../../sys/libcrypto.zig");

const js = @import("../../js/js.zig");
const algorithm = @import("algorithm.zig");
const common = @import("common.zig");

const CryptoKey = @import("../CryptoKey.zig");

const Execution = js.Execution;

/// The longest key generateKey makes, in bits. The length is an unsigned
/// long, so a page could ask for 512MB of key material (allocated twice); HMAC
/// hashes any key longer than the block size (1024 bits at most) down to it,
/// so nothing legitimate asks for more than this.
const max_generated_length = 1 << 16;

pub fn init(
    params: algorithm.Init.HmacKeyGen,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    // The union probe match to get here is pretty simple, so we can end up here
    // for an unknown/invalid algo.
    if (!std.ascii.eqlIgnoreCase(params.name, "HMAC")) {
        return error.NotSupported;
    }
    // Normalization converts the dictionary's members, then the hash: an
    // unrecognized one surfaces as NotSupportedError, before the usages.
    const length = try lengthParam(params.length, local);
    const hash_name = try params.hash.canonical(local);
    const digest = crypto.findDigest(hash_name) catch return error.NotSupported;

    // HMAC only accepts sign / verify; any other usage is a SyntaxError per
    // the spec, even when the entry exists elsewhere in CryptoKey.Usages.
    var mask: u8 = 0;
    for (key_usages) |usage| {
        if (std.mem.eql(u8, usage, "sign")) {
            mask |= CryptoKey.Usages.sign;
        } else if (std.mem.eql(u8, usage, "verify")) {
            mask |= CryptoKey.Usages.verify;
        } else {
            return error.SyntaxError;
        }
    }
    if (key_usages.len == 0) {
        return error.SyntaxError;
    }

    // In bits; by default, the block size of the hash function.
    const bits: u32 = length orelse @intCast(crypto.EVP_MD_block_size(digest) * 8);
    if (bits == 0 or bits > max_generated_length) {
        return error.OperationError;
    }

    // Enough bytes for `bits`, the ones past it in the last byte left zero.
    const key = try exec.local_arena.alloc(u8, (@as(usize, bits) + 7) / 8);

    // HMAC is simply CSPRNG.
    const res = crypto.RAND_bytes(key.ptr, key.len);
    lp.assert(res == 1, "HMAC.init", .{ .res = res });
    const remainder_bits: u3 = @intCast(bits % 8);
    if (remainder_bits != 0) {
        key[key.len - 1] &= ~(@as(u8, 0xFF) >> remainder_bits);
    }

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .hmac,
        ._extractable = extractable,
        ._usages = mask,
        ._key = key,
        ._algorithm = .{ .name = "HMAC", .hash = hash_name, .length = bits },
        ._vary = .{ .digest = digest },
    });

    return local.resolvePromise(crypto_key);
}

/// HmacKeyGenParams' and HmacImportParams' optional `length`, in bits: an
/// [EnforceRange] unsigned long, so a value outside u32 (NaN, the infinities)
/// is a TypeError. Undefined is no length; null converts to 0.
pub fn lengthParam(value: ?js.Value, local: *const js.Local) !?u32 {
    const v = value orelse return null;
    return js.enforceRange(u32, try v.toF64()) catch local.typeError("length is out of range");
}

/// Imports an HMAC key from a JWK, following the "jwk" steps of HMAC's "import
/// key": the usages first (SyntaxError), then kty "oct", the key in `k`, an
/// `alg` that names the hash ("HS256", ...), and the common use/key_ops/ext
/// checks (DataError). `length` is as for `import`.
pub fn importJwk(
    hash_name: []const u8,
    jwk: algorithm.KeyData.Jwk,
    length: ?u32,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const hash = common.canonicalHash(hash_name) orelse return error.NotSupported;
    const mask = try common.usageMask(&.{ "sign", "verify" }, key_usages);

    const raw = try common.octKey(jwk, exec.local_arena);
    if (jwk.alg) |alg| {
        if (!std.mem.eql(u8, alg, try jwkAlg(hash, exec))) return error.DataError;
    }
    try common.checkJwk(jwk, "sig", mask, extractable);

    // import() rejects an empty key, or a length that doesn't fit it (DataError).
    return import(hash, raw, length, extractable, key_usages, exec);
}

/// The JWK `alg` of an HMAC key with the given hash ("SHA-256" → "HS256").
pub fn jwkAlg(hash_name: []const u8, exec: *const Execution) ![]const u8 {
    return exec.local_arena.print("HS{s}", .{hash_name[4..]}); // strip "SHA-"
}

/// Imports raw HMAC key material (from the `raw` format, the `k` of a JWK
/// that `importJwk` checked, or deriveKey's bits). `length`, in bits, is
/// HmacImportParams': when given, it must end in the key's last byte (it can
/// leave some of its bits out), else DataError. The key bytes are kept whole.
pub fn import(
    hash_name: []const u8,
    raw: []const u8,
    length: ?u32,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const hash = common.canonicalHash(hash_name) orelse return error.NotSupported;
    const digest = crypto.findDigest(hash) catch return error.NotSupported;

    const mask = try common.usageMask(&.{ "sign", "verify" }, key_usages);

    if (raw.len == 0) {
        return error.DataError;
    }
    const data_bits = raw.len * 8;
    const bits: usize = length orelse data_bits;
    if (bits > data_bits or bits + 8 <= data_bits) {
        return error.DataError;
    }

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .hmac,
        ._kind = .secret,
        ._extractable = extractable,
        ._usages = mask,
        ._key = raw,
        ._algorithm = .{ .name = "HMAC", .hash = hash, .length = std.math.cast(u32, bits) orelse return error.DataError },
        ._vary = .{ .digest = digest },
    });

    return local.resolvePromise(crypto_key);
}

/// The MAC of `data` with the key. SubtleCrypto.sign checked the algorithm
/// and the sign usage.
pub fn sign(crypto_key: *const CryptoKey, data: []const u8, exec: *const Execution) ![]const u8 {
    const buffer = try exec.local_arena.alloc(u8, crypto.EVP_MD_size(crypto_key.getDigest()));
    return compute(crypto_key, data, buffer);
}

/// Whether `signature` is the MAC of `data` with the key. SubtleCrypto.verify
/// checked the algorithm and the verify usage.
pub fn verify(crypto_key: *const CryptoKey, signature: []const u8, data: []const u8) !bool {
    var buffer: [crypto.EVP_MAX_MD_SIZE]u8 = undefined;
    const mac = try compute(crypto_key, data, &buffer);
    // Check that lengths match; CRYPTO_memcmp can't cover this.
    if (signature.len != mac.len) {
        return false;
    }
    // CRYPTO_memcmp compare in constant time so prohibits time-based attacks.
    return crypto.CRYPTO_memcmp(mac.ptr, signature.ptr, signature.len) == 0;
}

/// The MAC of `data`, written to `out` (at least the digest's size).
fn compute(crypto_key: *const CryptoKey, data: []const u8, out: []u8) ![]const u8 {
    var out_len: c_uint = 0;
    _ = crypto.HMAC(
        crypto_key.getDigest(),
        @ptrCast(crypto_key._key.ptr),
        crypto_key._key.len,
        data.ptr,
        data.len,
        out.ptr,
        &out_len,
    ) orelse return error.OperationError;
    return out[0..out_len];
}

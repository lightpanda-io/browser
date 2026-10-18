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
    const hash_name = switch (params.hash) {
        .string => |str| str,
        .object => |obj| obj.name,
    };
    // Per spec, an unrecognized hash is caught during algorithm normalization
    // and surfaces as NotSupportedError.
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

    const block_size: usize = blk: {
        // Caller provides this in bits, not bytes.
        if (params.length) |length| {
            break :blk length >> 3;
        }
        // Prefer block size of the hash function instead.
        break :blk crypto.EVP_MD_block_size(digest);
    };
    // `block_size` cannot be 0.
    if (block_size == 0) {
        return error.OperationError;
    }

    // Should we reject this in promise too?
    const key = try exec.local_arena.alloc(u8, block_size);

    // HMAC is simply CSPRNG.
    const res = crypto.RAND_bytes(key.ptr, key.len);
    lp.assert(res == 1, "HMAC.init", .{ .res = res });

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .hmac,
        ._extractable = extractable,
        ._usages = mask,
        ._key = key,
        ._algorithm = .{ .name = "HMAC", .hash = hash_name },
        ._vary = .{ .digest = digest },
    });

    return local.resolvePromise(crypto_key);
}

/// Imports an HMAC key from a JWK, following the "jwk" steps of HMAC's "import
/// key": the usages first (SyntaxError), then kty "oct", the key in `k`, an
/// `alg` that names the hash ("HS256", ...), and the common use/key_ops/ext
/// checks (DataError).
pub fn importJwk(
    hash_name: []const u8,
    jwk: algorithm.KeyData.Jwk,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    _ = crypto.findDigest(hash_name) catch return error.NotSupported;
    const mask = try common.usageMask(&.{ "sign", "verify" }, key_usages);

    const raw = try common.octKey(jwk, exec.local_arena);
    if (jwk.alg) |alg| {
        if (!std.mem.eql(u8, alg, try jwkAlg(hash_name, exec))) return error.DataError;
    }
    try common.checkJwk(jwk, "sig", mask, extractable);

    // import() rejects an empty key (DataError).
    return import(hash_name, raw, extractable, key_usages, exec);
}

/// The JWK `alg` of an HMAC key with the given hash ("SHA-256" → "HS256").
pub fn jwkAlg(hash_name: []const u8, exec: *const Execution) ![]const u8 {
    return exec.local_arena.print("HS{s}", .{hash_name[4..]}); // strip "SHA-"
}

/// Imports raw HMAC key material (from the `raw` format, or the `k` of a JWK
/// that `importJwk` checked).
pub fn import(
    hash_name: []const u8,
    raw: []const u8,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const digest = crypto.findDigest(hash_name) catch return error.NotSupported;

    const mask = try common.usageMask(&.{ "sign", "verify" }, key_usages);

    if (raw.len == 0) {
        return error.DataError;
    }

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .hmac,
        ._kind = .secret,
        ._extractable = extractable,
        ._usages = mask,
        ._key = raw,
        ._algorithm = .{ .name = "HMAC", .hash = hash_name },
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

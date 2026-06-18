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

//! AES for AES-CBC/CTR/GCM/KW: key generation, import, and encrypt/decrypt
//! (CBC/CTR/GCM). Keys are raw byte strings; wrapKey/unwrapKey is not yet
//! implemented.

const std = @import("std");
const lp = @import("lightpanda");
const crypto = @import("../../../sys/libcrypto.zig");

const js = @import("../../js/js.zig");
const CryptoKey = @import("../CryptoKey.zig");

const common = @import("common.zig");
const algorithm = @import("algorithm.zig");

const Execution = js.Execution;

pub fn canonicalName(name: []const u8) ?[]const u8 {
    inline for ([_][]const u8{ "AES-CBC", "AES-CTR", "AES-GCM", "AES-KW" }) |canonical| {
        if (eqlIgnoreCase(name, canonical)) return canonical;
    }
    return null;
}

/// The usages permitted for the given AES variant.
fn allowedUsages(name: []const u8) ?[]const []const u8 {
    if (eqlIgnoreCase(name, "AES-CBC") or eqlIgnoreCase(name, "AES-CTR") or eqlIgnoreCase(name, "AES-GCM")) {
        return &.{ "encrypt", "decrypt", "wrapKey", "unwrapKey" };
    }
    if (eqlIgnoreCase(name, "AES-KW")) {
        return &.{ "wrapKey", "unwrapKey" };
    }
    return null;
}

/// Per WebCrypto: "Generate Key" operation for AES-CBC/CTR/GCM/KW.
/// Validation order matches the spec: usages → length → empty usages.
pub fn validate(params: algorithm.Init.AesKeyGen, key_usages: []const []const u8) !void {
    const allowed = allowedUsages(params.name) orelse return error.NotSupported;

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

    if (params.length != 128 and params.length != 192 and params.length != 256) {
        return error.OperationError;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

/// Generates a fresh AES key (random bytes of the requested length).
pub fn generate(
    params: algorithm.Init.AesKeyGen,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    validate(params, key_usages) catch |err| {
        return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
    };

    // validate() already confirmed the usages and length are well-formed.
    const allowed = allowedUsages(params.name).?;
    const mask = common.usageMask(allowed, key_usages) catch unreachable;

    const key = try exec.arena.alloc(u8, params.length / 8);

    const res = crypto.RAND_bytes(key.ptr, key.len);
    lp.assert(res == 1, "AES.generate", .{ .res = res });

    const crypto_key = try exec._factory.create(CryptoKey{
        ._type = .aes,
        ._kind = .secret,
        ._extractable = extractable,
        ._usages = mask,
        ._key = key,
        ._algorithm = .{ .name = canonicalName(params.name).? },
    });

    return local.resolvePromise(crypto_key);
}

/// Imports raw AES key material (from the `raw` or `jwk` formats; the caller has
/// already turned both into the underlying bytes).
pub fn import(
    name: []const u8,
    raw: []const u8,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const canonical = canonicalName(name) orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };

    const mask = common.usageMask(allowedUsages(name).?, key_usages) catch |err| {
        return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
    };

    if (raw.len != 16 and raw.len != 24 and raw.len != 32) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    }

    const key = try exec.arena.dupe(u8, raw);
    const crypto_key = try exec._factory.create(CryptoKey{
        ._type = .aes,
        ._kind = .secret,
        ._extractable = extractable,
        ._usages = mask,
        ._key = key,
        ._algorithm = .{ .name = canonical },
    });

    return local.resolvePromise(crypto_key);
}

pub const CipherError = error{ InvalidAccessError, OperationError, NotSupported, OutOfMemory };

const Mode = enum { cbc, ctr, gcm };

fn modeFor(name: []const u8) ?Mode {
    if (eqlIgnoreCase(name, "AES-CBC")) return .cbc;
    if (eqlIgnoreCase(name, "AES-CTR")) return .ctr;
    if (eqlIgnoreCase(name, "AES-GCM")) return .gcm;
    return null;
}

fn cipherFor(mode: Mode, key_len: usize) ?*const crypto.EVP_CIPHER {
    return switch (mode) {
        .cbc => switch (key_len) {
            16 => crypto.EVP_aes_128_cbc(),
            24 => crypto.EVP_aes_192_cbc(),
            32 => crypto.EVP_aes_256_cbc(),
            else => null,
        },
        .ctr => switch (key_len) {
            16 => crypto.EVP_aes_128_ctr(),
            24 => crypto.EVP_aes_192_ctr(),
            32 => crypto.EVP_aes_256_ctr(),
            else => null,
        },
        .gcm => switch (key_len) {
            16 => crypto.EVP_aes_128_gcm(),
            24 => crypto.EVP_aes_192_gcm(),
            32 => crypto.EVP_aes_256_gcm(),
            else => null,
        },
    };
}

/// AES encrypt (`encrypting = true`) or decrypt. Returns the resulting bytes
/// (ciphertext for GCM includes the appended tag).
pub fn crypt(
    params: anytype, // algorithm.Encrypt.params
    key: *const CryptoKey,
    data: []const u8,
    encrypting: bool,
    exec: *const Execution,
) CipherError![]const u8 {
    const mode = modeFor(params.name) orelse return error.NotSupported;

    // The key must be an AES key for this exact algorithm, with the matching
    // usage.
    if (key._type != .aes or !eqlIgnoreCase(key._algorithm.name, params.name)) {
        return error.InvalidAccessError;
    }
    if ((encrypting and !key.canEncrypt()) or (!encrypting and !key.canDecrypt())) {
        return error.InvalidAccessError;
    }

    const cipher = cipherFor(mode, key._key.len) orelse return error.OperationError;
    return switch (mode) {
        .cbc => cbcOrCtr(cipher, key._key, ivOf(params.iv) orelse return error.OperationError, data, encrypting, true, exec),
        .ctr => blk: {
            // The counter `length` (bits of the block used as the counter) must
            // be in 1..128.
            const len = params.length orelse return error.OperationError;
            if (len == 0 or len > 128) return error.OperationError;
            break :blk ctr(cipher, key._key, ivOf(params.counter) orelse return error.OperationError, len, data, encrypting, exec);
        },
        .gcm => gcm(cipher, key._key, params, data, encrypting, exec),
    };
}

fn ivOf(opt: anytype) ?[]const u8 {
    const v = opt orelse return null;
    return v.values;
}

/// Reads a 16-byte counter block as a big-endian 128-bit integer.
fn readBlock(b: []const u8) u128 {
    var tmp: [16]u8 = undefined;
    @memcpy(&tmp, b[0..16]);
    return std.mem.readInt(u128, &tmp, .big);
}

/// OpenSSL's CTR increments the whole 128-bit block, but the spec only
/// increments the rightmost `counter_bits` (the nonce occupies the rest). They
/// agree until that sub-counter overflows, so split the message at the wrap
/// point and restart the second part with the sub-counter reset to zero.
fn ctr(
    cipher: *const crypto.EVP_CIPHER,
    key: []const u8,
    counter: []const u8,
    counter_bits: u32,
    data: []const u8,
    encrypting: bool,
    exec: *const Execution,
) CipherError![]const u8 {
    if (counter.len != 16) return error.OperationError;

    if (counter_bits < 128) {
        const num_blocks: u128 = (data.len + 15) / 16;
        const counter_range = @as(u128, 1) << @intCast(counter_bits);
        // More blocks than the counter can represent would reuse counter values.
        if (num_blocks > counter_range) return error.OperationError;

        const mask = counter_range - 1;
        const counter_value = readBlock(counter) & mask;
        const before_wrap = counter_range - counter_value; // >= 1

        if (num_blocks > before_wrap) {
            const split = @as(usize, @intCast(before_wrap)) * 16;
            const first = try cbcOrCtr(cipher, key, counter, data[0..split], encrypting, false, exec);

            // Second part: keep the nonce bits, zero the sub-counter.
            var wrapped: [16]u8 = undefined;
            std.mem.writeInt(u128, &wrapped, readBlock(counter) & ~mask, .big);
            const second = try cbcOrCtr(cipher, key, &wrapped, data[split..], encrypting, false, exec);

            const out = try exec.call_arena.alloc(u8, data.len);
            @memcpy(out[0..split], first);
            @memcpy(out[split..], second);
            return out;
        }
    }

    return cbcOrCtr(cipher, key, counter, data, encrypting, false, exec);
}

// libcrypto's EVP_*Init/Update/Final are distinct functions for encrypt vs
// decrypt; extern fns can't be selected into a runtime variable, so branch here.
fn cipherInit(ctx: *crypto.EVP_CIPHER_CTX, cipher: ?*const crypto.EVP_CIPHER, key: [*c]const u8, iv: [*c]const u8, encrypting: bool) c_int {
    return if (encrypting)
        crypto.EVP_EncryptInit_ex(ctx, cipher, null, key, iv)
    else
        crypto.EVP_DecryptInit_ex(ctx, cipher, null, key, iv);
}

fn cipherUpdate(ctx: *crypto.EVP_CIPHER_CTX, out: [*c]u8, out_len: *c_int, in: [*c]const u8, in_len: c_int, encrypting: bool) c_int {
    return if (encrypting)
        crypto.EVP_EncryptUpdate(ctx, out, out_len, in, in_len)
    else
        crypto.EVP_DecryptUpdate(ctx, out, out_len, in, in_len);
}

fn cbcOrCtr(
    cipher: *const crypto.EVP_CIPHER,
    key: []const u8,
    iv: []const u8,
    data: []const u8,
    encrypting: bool,
    padded: bool, // CBC pads, CTR does not
    exec: *const Execution,
) CipherError![]const u8 {
    if (iv.len != 16) return error.OperationError;

    const ctx = crypto.EVP_CIPHER_CTX_new() orelse return error.OutOfMemory;
    defer crypto.EVP_CIPHER_CTX_free(ctx);

    if (cipherInit(ctx, cipher, @ptrCast(key.ptr), @ptrCast(iv.ptr), encrypting) != 1) {
        return error.OperationError;
    }
    if (!padded) {
        _ = crypto.EVP_CIPHER_CTX_set_padding(ctx, 0);
    }

    // Block ciphers may emit up to one extra block on top of the input.
    const out = try exec.call_arena.alloc(u8, data.len + 16);
    var out_len: c_int = 0;
    if (cipherUpdate(ctx, out.ptr, &out_len, @ptrCast(data.ptr), @intCast(data.len), encrypting) != 1) {
        return error.OperationError;
    }

    var final_len: c_int = 0;
    const tail = out.ptr + @as(usize, @intCast(out_len));
    // Decrypt final fails on bad padding → OperationError, per spec.
    const final_ok = if (encrypting)
        crypto.EVP_EncryptFinal_ex(ctx, tail, &final_len)
    else
        crypto.EVP_DecryptFinal_ex(ctx, tail, &final_len);
    if (final_ok != 1) {
        return error.OperationError;
    }

    return out[0..@intCast(out_len + final_len)];
}

fn gcm(
    cipher: *const crypto.EVP_CIPHER,
    key: []const u8,
    params: anytype,
    data: []const u8,
    encrypting: bool,
    exec: *const Execution,
) CipherError![]const u8 {
    const iv = ivOf(params.iv) orelse return error.OperationError;

    const tag_bits = params.tagLength orelse 128;
    switch (tag_bits) {
        32, 64, 96, 104, 112, 120, 128 => {},
        else => return error.OperationError,
    }
    const tag_len: usize = tag_bits / 8;

    const ctx = crypto.EVP_CIPHER_CTX_new() orelse return error.OutOfMemory;
    defer crypto.EVP_CIPHER_CTX_free(ctx);

    if (cipherInit(ctx, cipher, null, null, encrypting) != 1) return error.OperationError;
    if (crypto.EVP_CIPHER_CTX_ctrl(ctx, crypto.EVP_CTRL_GCM_SET_IVLEN, @intCast(iv.len), null) != 1) {
        return error.OperationError;
    }
    if (cipherInit(ctx, null, @ptrCast(key.ptr), @ptrCast(iv.ptr), encrypting) != 1) return error.OperationError;

    // Additional authenticated data (optional), fed with a null output buffer.
    if (ivOf(params.additionalData)) |aad| {
        if (aad.len > 0) {
            var aad_len: c_int = 0;
            if (cipherUpdate(ctx, null, &aad_len, @ptrCast(aad.ptr), @intCast(aad.len), encrypting) != 1) {
                return error.OperationError;
            }
        }
    }

    if (encrypting) {
        const out = try exec.call_arena.alloc(u8, data.len + tag_len);
        var out_len: c_int = 0;
        if (data.len > 0 and cipherUpdate(ctx, out.ptr, &out_len, @ptrCast(data.ptr), @intCast(data.len), true) != 1) {
            return error.OperationError;
        }
        var final_len: c_int = 0;
        if (crypto.EVP_EncryptFinal_ex(ctx, out.ptr + @as(usize, @intCast(out_len)), &final_len) != 1) {
            return error.OperationError;
        }
        const written: usize = @intCast(out_len + final_len);
        // Append the authentication tag.
        if (crypto.EVP_CIPHER_CTX_ctrl(ctx, crypto.EVP_CTRL_GCM_GET_TAG, @intCast(tag_len), out.ptr + written) != 1) {
            return error.OperationError;
        }
        return out[0 .. written + tag_len];
    }

    // Decrypt: the ciphertext carries the tag as its final `tag_len` bytes.
    if (data.len < tag_len) return error.OperationError;
    const ct = data[0 .. data.len - tag_len];
    const tag = data[data.len - tag_len ..];

    if (crypto.EVP_CIPHER_CTX_ctrl(ctx, crypto.EVP_CTRL_GCM_SET_TAG, @intCast(tag_len), @ptrCast(@constCast(tag.ptr))) != 1) {
        return error.OperationError;
    }

    const out = try exec.call_arena.alloc(u8, ct.len + 16);
    var out_len: c_int = 0;
    if (ct.len > 0 and cipherUpdate(ctx, out.ptr, &out_len, @ptrCast(ct.ptr), @intCast(ct.len), false) != 1) {
        return error.OperationError;
    }
    var final_len: c_int = 0;
    // Tag verification happens here: failure → OperationError.
    if (crypto.EVP_DecryptFinal_ex(ctx, out.ptr + @as(usize, @intCast(out_len)), &final_len) != 1) {
        return error.OperationError;
    }
    return out[0..@intCast(out_len + final_len)];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

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

const std = @import("std");
const lp = @import("lightpanda");
const crypto = @import("../../sys/libcrypto.zig");

const js = @import("../js/js.zig");

const CryptoKey = @import("CryptoKey.zig");

const algorithm = @import("crypto/algorithm.zig");
const AES = @import("crypto/AES.zig");
const EC = @import("crypto/EC.zig");
const HMAC = @import("crypto/HMAC.zig");
const RSA = @import("crypto/RSA.zig");
const X25519 = @import("crypto/X25519.zig");
const KDF = @import("crypto/KDF.zig");
const OKP = @import("crypto/OKP.zig");
const common = @import("crypto/common.zig");

const log = lp.log;
const Execution = js.Execution;
const missing_name = algorithm.missing_name;

/// The SubtleCrypto interface of the Web Crypto API provides a number of low-level
/// cryptographic functions.
/// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto
/// https://w3c.github.io/webcrypto/#subtlecrypto-interface
const SubtleCrypto = @This();
/// Don't optimize away the type.
_pad: bool = false,

/// Generate a new key (for symmetric algorithms) or key pair (for public-key algorithms).
pub fn generateKey(
    _: *const SubtleCrypto,
    algo_value: js.Value,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    switch (try algorithm.Init.fromJs(algo_value, exec.js.local.?)) {
        .hmac_key_gen => |params| return HMAC.init(params, extractable, key_usages, exec),
        .aes_key_gen => |params| return AES.generate(params, extractable, key_usages, exec),
        .ec_key_gen => |params| return EC.generate(params, extractable, key_usages, exec),
        .rsa_hashed_key_gen => |params| return RSA.generate(params, extractable, key_usages, exec),
        .named => |name| return generateKeyFromName(name, extractable, key_usages, exec),
    }
}

fn generateKeyFromName(
    name: []const u8,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    if (OKP.curveOf(name)) |curve| {
        return OKP.generate(curve, extractable, key_usages, exec);
    }

    {
        // Algorithms whose `generateKey` parameters are just `{name}` — Ed448,
        // X448. Validates usages so failure-path tests get the spec-mandated
        // error name; leaves real key generation to a future change.

        const allowed: []const []const u8 = blk: {
            if (eqlIgnoreCase(name, "Ed448")) {
                break :blk &.{ "sign", "verify" };
            }
            if (eqlIgnoreCase(name, "X448")) {
                break :blk &.{ "deriveKey", "deriveBits" };
            }
            return error.NotSupported;
        };

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

        if (key_usages.len == 0) {
            return error.SyntaxError;
        }
    }

    log.debug(.not_implemented, "generateKey", .{ .name = name });
    return error.NotSupported;
}

/// Imports a key from an external, portable format and returns a `CryptoKey`.
pub fn importKey(
    _: *const SubtleCrypto,
    format: []const u8,
    key_data_value: js.Value,
    algo_value: js.Value,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkFormat(format, local);
    // keyData converts first (a JWK's members are read then), but a buffer's
    // bytes are only read after the algorithm is normalized (bufferBytes).
    // Any ArrayBuffer or view is the BufferSource (a Uint16Array too, which
    // KeyData's Uint8Array wouldn't take); a shared one is one that fails its
    // conversion (TypeError), not a JsonWebKey. Any other object is a JWK.
    const is_buffer = key_data_value.isArrayBuffer() or key_data_value.isArrayBufferView() or key_data_value.isSharedArrayBuffer();
    var key_data: algorithm.KeyData = if (is_buffer) blk: {
        try checkBufferSource(key_data_value, local);
        break :blk .{ .bytes = .{ .values = &.{} } };
    } else local.jsValueToZig(algorithm.KeyData, key_data_value) catch |err| {
        return algorithm.conversionError(err, local, "keyData is neither a BufferSource nor a JsonWebKey");
    };
    const algo = try algorithm.Import.fromJs(algo_value, local);
    if (key_data == .bytes) {
        key_data = .{ .bytes = .{ .values = try bufferBytes(key_data_value, local) } };
    }
    return importNormalized(format, key_data, algo, extractable, key_usages, exec);
}

/// importKey, once its algorithm is normalized: unwrapKey normalizes the
/// unwrapped key's algorithm itself, before unwrapping.
fn importNormalized(
    requested_format: []const u8,
    key_data: algorithm.KeyData,
    algo: algorithm.Import,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const name = algo.algoName();
    const symmetric = AES.canonicalName(name) != null or eqlIgnoreCase(name, "HMAC") or
        eqlIgnoreCase(name, "HKDF") or eqlIgnoreCase(name, "PBKDF2");
    const raw_public = EC.canonicalName(name) != null or OKP.curveOf(name) != null;
    const format = rawAlias(requested_format, symmetric, raw_public);

    // Asymmetric algorithms (EC, OKP). Usage validation runs first (bad/empty
    // usages → SyntaxError) so the failure-path tests pass regardless of whether
    // the key material itself can be parsed yet.
    const is_private = importKind(format, key_data);
    if (asymmetricAllowedUsages(name, is_private)) |allowed| {
        // Public keys may have empty usages; secret/private keys may not.
        const mask = try common.usageMaskInner(allowed, key_usages, is_private);
        if (EC.canonicalName(name) != null) {
            const is_jwk = std.mem.eql(u8, format, "jwk");
            switch (key_data) {
                .bytes => |b| {
                    if (is_jwk) return local.typeError("jwk format expects an object");
                    return EC.import(name, algo.namedCurve(), format, b.values, is_private, extractable, mask, exec);
                },
                .jwk => |jwk| {
                    if (!is_jwk) return local.typeError("this format expects a BufferSource");
                    return EC.importJwk(name, algo.namedCurve(), jwk, extractable, mask, exec);
                },
            }
        }
        if (OKP.curveOf(name)) |curve| {
            const is_jwk = std.mem.eql(u8, format, "jwk");
            switch (key_data) {
                .bytes => |b| {
                    if (is_jwk) return local.typeError("jwk format expects an object");
                    return OKP.import(curve, format, b.values, is_private, extractable, mask, exec);
                },
                .jwk => |jwk| {
                    if (!is_jwk) return local.typeError("this format expects a BufferSource");
                    return OKP.importJwk(curve, jwk, extractable, mask, exec);
                },
            }
        }
        if (RSA.scheme(name)) |scheme| {
            const hash_name = (try algo.hash(local)).?;
            const is_jwk = std.mem.eql(u8, format, "jwk");
            switch (key_data) {
                .bytes => |b| {
                    if (is_jwk) return local.typeError("jwk format expects an object");
                    return RSA.import(scheme, format, b.values, hash_name, is_private, extractable, mask, exec);
                },
                .jwk => |jwk| {
                    if (!is_jwk) return local.typeError("this format expects a BufferSource");
                    return RSA.importJwk(scheme, jwk, hash_name, extractable, mask, exec);
                },
            }
        }
        log.debug(.not_implemented, "SubtleCrypto.importKey", .{ .name = name });
        return error.NotSupported;
    }

    // Symmetric keys come in "raw" (a BufferSource) or, for AES and HMAC, "jwk"
    // (an "oct" JSON Web Key, which each checks against the key it imports).
    if (std.mem.eql(u8, format, "jwk")) {
        const jwk = switch (key_data) {
            .jwk => |j| j,
            .bytes => return local.typeError("jwk format expects an object"),
        };
        if (AES.canonicalName(name) != null) {
            return AES.importJwk(name, jwk, extractable, key_usages, exec);
        }
        if (eqlIgnoreCase(name, "HMAC")) {
            const length = try HMAC.lengthParam(algo.length(), local);
            const hash_name = (try algo.hash(local)).?;
            return HMAC.importJwk(hash_name, jwk, length, extractable, key_usages, exec);
        }
        // HKDF and PBKDF2 keys only come in "raw".
        log.debug(.not_implemented, "SubtleCrypto.importKey", .{ .name = name, .format = format });
        return error.NotSupported;
    }

    const raw: []const u8 = blk: {
        if (std.mem.eql(u8, format, "raw")) {
            break :blk switch (key_data) {
                .bytes => |b| b.values,
                // A JWK object passed where a BufferSource is expected.
                .jwk => return local.typeError("raw format expects a BufferSource"),
            };
        }
        // spki / pkcs8 (asymmetric formats) are not supported for these algorithms.
        return error.NotSupported;
    };

    if (AES.canonicalName(name) != null) {
        return AES.import(name, raw, extractable, key_usages, exec);
    }

    // HKDF / PBKDF2: key-derivation inputs. The raw bytes are the key; there's
    // no length constraint and these keys are never extractable.
    inline for ([_][]const u8{ "HKDF", "PBKDF2" }) |derive_name| {
        if (eqlIgnoreCase(name, derive_name)) {
            const mask = try common.usageMask(&.{ "deriveKey", "deriveBits" }, key_usages);
            if (extractable) return error.SyntaxError;
            const crypto_key = try CryptoKey.init(exec, .{
                ._type = .derive,
                ._kind = .secret,
                ._extractable = extractable,
                ._usages = mask,
                ._key = raw,
                ._algorithm = .{ .name = derive_name },
            });
            return local.resolvePromise(crypto_key);
        }
    }
    if (eqlIgnoreCase(name, "HMAC")) {
        const length = try HMAC.lengthParam(algo.length(), local);
        const hash_name = (try algo.hash(local)).?;
        return HMAC.import(hash_name, raw, length, extractable, key_usages, exec);
    }

    log.debug(.not_implemented, "SubtleCrypto.importKey", .{ .name = name });
    return error.NotSupported;
}

/// Whether the requested format/key-data describe a private key. The format
/// alone decides for DER/raw variants; for JWK the presence of `d` marks it.
fn importKind(format: []const u8, key_data: algorithm.KeyData) bool {
    if (std.mem.eql(u8, format, "pkcs8") or std.mem.eql(u8, format, "raw-private") or std.mem.eql(u8, format, "raw-seed")) {
        return true;
    }
    if (std.mem.eql(u8, format, "jwk")) {
        return switch (key_data) {
            .jwk => |j| j.d != null,
            .bytes => false,
        };
    }
    // spki, raw, raw-public, ...
    return false;
}

/// The usages permitted for an EC/OKP/RSA key of the given privacy, or null if
/// the algorithm isn't one of the asymmetric algorithms handled here. Only EC,
/// RSA, Ed25519 and X25519 import their keys; for the others this only drives
/// usage validation.
fn asymmetricAllowedUsages(name: []const u8, is_private: bool) ?[]const []const u8 {
    if (eqlIgnoreCase(name, "ECDSA") or eqlIgnoreCase(name, "Ed25519") or eqlIgnoreCase(name, "Ed448")) {
        return if (is_private) &.{"sign"} else &.{"verify"};
    }
    if (eqlIgnoreCase(name, "ECDH") or eqlIgnoreCase(name, "X25519") or eqlIgnoreCase(name, "X448")) {
        return if (is_private) &.{ "deriveKey", "deriveBits" } else &.{};
    }
    if (RSA.scheme(name)) |scheme| {
        return if (is_private) scheme.private_usages else scheme.public_usages;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Exports a key: that is, it takes as input a CryptoKey object and gives you
/// the key in an external, portable format.
pub fn exportKey(
    _: *const SubtleCrypto,
    format: []const u8,
    key: *CryptoKey,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkFormat(format, local);
    return switch (try exportAs(format, key, exec)) {
        .bytes => |bytes| local.resolvePromise(js.ArrayBuffer{ .values = bytes }),
        .jwk => |jwk| local.resolvePromise(try jwk.toJs(local)),
    };
}

/// A key exported in some format: the key's bytes (raw, spki, pkcs8), or its
/// JWK.
const Exported = union(enum) {
    bytes: []const u8,
    jwk: Jwk,
};

/// A key's JWK, as the struct it's built from: exportKey resolves it as an
/// object, wrapKey serializes it here. Going through V8's JSON.stringify would
/// let the page steer the wrapped bytes with an inherited `toJSON`; the spec
/// stringifies "in the context of a new global object".
const Jwk = union(enum) {
    secret: JwkSecret,
    rsa: RSA.Jwk,
    ec: EC.Jwk,
    okp: OKP.Jwk,

    fn toJs(self: Jwk, local: *const js.Local) !js.Value {
        return switch (self) {
            .secret => |jwk| local.zigValueToJs(jwk, .{}),
            inline .rsa, .ec, .okp => |asymmetric| switch (asymmetric) {
                inline else => |jwk| local.zigValueToJs(jwk, .{}),
            },
        };
    }

    /// The JSON text, identical to `JSON.stringify` of the object: members
    /// are declared in the order they'd be set.
    fn toJson(self: Jwk, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .secret => |jwk| std.json.Stringify.valueAlloc(allocator, jwk, .{}),
            inline .rsa, .ec, .okp => |asymmetric| switch (asymmetric) {
                inline else => |jwk| std.json.Stringify.valueAlloc(allocator, jwk, .{}),
            },
        };
    }
};

/// The "export key" steps shared by exportKey and wrapKey.
fn exportAs(requested_format: []const u8, key: *CryptoKey, exec: *const Execution) !Exported {
    // HKDF and PBKDF2 have no export operation: that's a NotSupportedError,
    // checked before the extractable flag (their keys never are).
    if (key._type == .derive) {
        return error.NotSupported;
    }
    if (!key.canExportKey()) {
        return error.InvalidAccessError;
    }

    const symmetric = key._type == .aes or key._type == .hmac;
    const raw_public = key._type == .ec or key._type == .ed25519 or key._type == .x25519;
    const format = rawAlias(requested_format, symmetric, raw_public);

    if (std.mem.eql(u8, format, "raw")) {
        // RSA keys live in `_vary.pkey`; there's no raw form.
        if (key._type == .rsa) {
            return error.NotSupported;
        }
        // Only the public half of an asymmetric key has a raw form.
        if (key._kind == .private) {
            return error.InvalidAccessError;
        }
        // EC keys live in `_vary.pkey` too, with no bytes in `_key`: their raw
        // form is the public point.
        if (key._type == .ec) {
            return .{ .bytes = try EC.exportRaw(key, exec) };
        }
        if (key._type == .ed25519 or key._type == .x25519) {
            return .{ .bytes = try OKP.exportRaw(key, exec) };
        }
        return .{ .bytes = key._key };
    }

    if (std.mem.eql(u8, format, "jwk")) {
        return .{ .jwk = try exportJwk(key, exec) };
    }

    const is_der = std.mem.eql(u8, format, "pkcs8") or std.mem.eql(u8, format, "spki");
    if (is_der) {
        if (key._type == .rsa or key._type == .ec or key._type == .ed25519 or key._type == .x25519) {
            return .{ .bytes = try common.exportDer(format, key, exec) };
        }
        log.debug(.not_implemented, "SubtleCrypto.exportKey", .{ .format = format });
        return error.NotSupported;
    }

    // raw-private or raw-seed, or a raw-* format the key's algorithm doesn't
    // take (see rawAlias).
    return error.NotSupported;
}

/// The Modern Algorithms draft's raw-* formats, for the algorithms here:
/// "raw-secret" is "raw" for a symmetric algorithm, and "raw-public" is "raw"
/// for an EC or OKP one (a public key's point). Any other format stays as it
/// is, so a raw-* one the algorithm doesn't take (raw-public on AES, raw-secret
/// on ECDSA, any raw-* on RSA, raw-private, raw-seed) is NotSupportedError.
/// https://wicg.github.io/webcrypto-modern-algos/#subtlecrypto-interface-keyformat
fn rawAlias(format: []const u8, symmetric: bool, raw_public: bool) []const u8 {
    if (symmetric and std.mem.eql(u8, format, "raw-secret")) return "raw";
    if (raw_public and std.mem.eql(u8, format, "raw-public")) return "raw";
    return format;
}

/// The JSON Web Key returned for symmetric ("oct") keys. Members are listed
/// in lexicographic order, the order browsers return a JsonWebKey in, which is
/// also the order wrapKey serializes them in.
const JwkSecret = struct {
    alg: []const u8,
    ext: bool,
    k: []const u8,
    key_ops: []const []const u8,
    kty: []const u8 = "oct",
};

fn exportJwk(key: *CryptoKey, exec: *const Execution) !Jwk {
    // The `alg` registry value depends on the algorithm and key length.
    const alg: []const u8 = switch (key._type) {
        .aes => try AES.jwkAlg(key._algorithm.name, key._key.len, exec),
        .hmac => try HMAC.jwkAlg(key._algorithm.hash orelse "SHA-", exec),
        .rsa => return .{ .rsa = try RSA.exportJwk(key, exec) },
        .ec => return .{ .ec = try EC.exportJwk(key, exec) },
        .ed25519, .x25519 => return .{ .okp = try OKP.exportJwk(key, exec) },
        else => {
            log.debug(.not_implemented, "SubtleCrypto.exportKey", .{ .format = "jwk", .type = key._type });
            return error.NotSupported;
        },
    };

    return .{ .secret = .{
        .alg = alg,
        .ext = key._extractable,
        .k = try common.base64Encode(exec.local_arena, key._key),
        .key_ops = try key.getUsages(exec),
    } };
}

/// Derive an array of bits from a base key. `length` is in bits and may be null
/// (the WebIDL type is `[EnforceRange] unsigned long?`).
pub fn deriveBits(
    _: *const SubtleCrypto,
    algo_value: js.Value,
    base_key: *const CryptoKey,
    length: ?js.EnforceRange(u32),
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const algo = try algorithm.Derive.fromJs(algo_value, local);
    const bits = try deriveRaw(algo, base_key, if (length) |l| l.value else null, base_key.canDeriveBits(), exec);
    return local.resolvePromise(js.ArrayBuffer{ .values = bits });
}

/// Derive a new CryptoKey from a base key: derive the right number of bits for
/// `derived`, then import them as that key type.
pub fn deriveKey(
    _: *const SubtleCrypto,
    algo_value: js.Value,
    base_key: *const CryptoKey,
    derived_value: js.Value,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    // The algorithm is normalized before derivedKeyType.
    const algo = try algorithm.Derive.fromJs(algo_value, local);
    const derived = try algorithm.DerivedKey.fromJs(derived_value, local);
    // The base key checks come before "get key length": its algorithm must be
    // the one given, and it must have the deriveKey usage (not deriveBits).
    if (!eqlIgnoreCase(base_key._algorithm.name, algo.algoName())) {
        return error.InvalidAccessError;
    }
    const usage_ok = base_key.canDeriveKey();
    if (!usage_ok) {
        return error.InvalidAccessError;
    }

    switch (derived) {
        .aes => |a| {
            // "Get key length": an AES key is 128, 192 or 256 bits.
            const length = a.length.value;
            if (length != 128 and length != 192 and length != 256) {
                return error.OperationError;
            }
            const bits = try deriveRaw(algo, base_key, length, usage_ok, exec);
            return AES.import(a.name, bits, extractable, key_usages, exec);
        },
        .hmac => |h| {
            // "Get key length": a present length must be non-zero.
            if (h.length == 0) {
                return local.typeError("HMAC length must not be zero");
            }
            const hash_name = try h.hash.canonical(local);
            const hash_md = crypto.findDigest(hash_name) catch return error.NotSupported;
            // Default length, per spec, is the hash's block size (in bits).
            const length: u32 = h.length orelse @intCast(crypto.EVP_MD_block_size(hash_md) * 8);
            const bits = try deriveRaw(algo, base_key, length, usage_ok, exec);
            return HMAC.import(hash_name, bits, length, extractable, key_usages, exec);
        },
        // HKDF and PBKDF2 have no key length: the whole derivation, which only
        // ECDH and X25519 can give (PBKDF2 and HKDF need a length).
        .named => {
            const bits = try deriveRaw(algo, base_key, null, usage_ok, exec);
            return importNormalized("raw", .{ .bytes = .{ .values = bits } }, .{ .named = derived.named }, extractable, key_usages, exec);
        },
    }
}

/// Shared derivation core for deriveBits/deriveKey. `usage_ok` is the relevant
/// usage gate already evaluated by the caller. Returns the raw derived bytes.
fn deriveRaw(
    algo: algorithm.Derive,
    base_key: *const CryptoKey,
    length: ?u32,
    usage_ok: bool,
    exec: *const Execution,
) KDF.Error![]const u8 {
    switch (algo) {
        .pbkdf2 => |params| return KDF.pbkdf2(base_key, params, length, usage_ok, exec),
        .hkdf => |params| return KDF.hkdf(base_key, params, length, usage_ok, exec),
        .ecdh_or_x25519 => |params| {
            if (!usage_ok) {
                return error.InvalidAccessError;
            }
            // The base key must have been created for this same algorithm.
            if (!eqlIgnoreCase(base_key._algorithm.name, params.name)) {
                return error.InvalidAccessError;
            }
            if (eqlIgnoreCase(params.name, "X25519")) {
                return X25519.deriveBits(base_key, params.public, length, exec);
            }
            if (eqlIgnoreCase(params.name, "ECDH")) {
                return EC.deriveBits(base_key, params.public, length, exec);
            }
            return error.NotSupported;
        },
    }
}

/// Encrypts data with the given key and algorithm.
pub fn encrypt(
    _: *const SubtleCrypto,
    algo_value: js.Value,
    key: *CryptoKey,
    data_value: js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkBufferSource(data_value, local);
    const algo = try algorithm.Encrypt.fromJs(algo_value, local, false);
    const data = try bufferBytes(data_value, local);
    const out = try cryptBytes(algo, key, data, .encrypt, exec);
    return local.resolvePromise(js.ArrayBuffer{ .values = out });
}

/// Decrypts data with the given key and algorithm.
pub fn decrypt(
    _: *const SubtleCrypto,
    algo_value: js.Value,
    key: *CryptoKey,
    data_value: js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkBufferSource(data_value, local);
    const algo = try algorithm.Encrypt.fromJs(algo_value, local, false);
    const data = try bufferBytes(data_value, local);
    const out = try cryptBytes(algo, key, data, .decrypt, exec);
    return local.resolvePromise(js.ArrayBuffer{ .values = out });
}

/// Wraps a key: exports it in `format` (a JWK as its JSON text) and encrypts
/// the result with `wrapping_key`, or wraps it with AES-KW.
pub fn wrapKey(
    _: *const SubtleCrypto,
    format: []const u8,
    key: *CryptoKey,
    wrapping_key: *CryptoKey,
    algo_value: js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkFormat(format, local);
    const algo = try algorithm.Encrypt.fromJs(algo_value, local, true);
    try checkWrappingKey(algo.algoName(), wrapping_key, .wrap);

    const bytes = switch (try exportAs(format, key, exec)) {
        .bytes => |bytes| bytes,
        .jwk => |jwk| try jwk.toJson(exec.local_arena),
    };
    const out = try cryptBytes(algo, wrapping_key, bytes, .wrap, exec);
    return local.resolvePromise(js.ArrayBuffer{ .values = out });
}

/// Unwraps a key: decrypts `wrapped_key` with `unwrapping_key` (or unwraps it
/// with AES-KW) and imports the result in `format`, a JWK being its JSON text.
pub fn unwrapKey(
    _: *const SubtleCrypto,
    format: []const u8,
    wrapped_key_value: js.Value,
    unwrapping_key: *CryptoKey,
    algo_value: js.Value,
    unwrapped_key_value: js.Value,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkFormat(format, local);
    try checkBufferSource(wrapped_key_value, local);
    const algo = try algorithm.Encrypt.fromJs(algo_value, local, true);
    // The unwrapped key's algorithm is normalized next, before the key checks.
    const unwrapped_key_algo = try algorithm.Import.fromJs(unwrapped_key_value, local);
    const wrapped_key = try bufferBytes(wrapped_key_value, local);
    try checkWrappingKey(algo.algoName(), unwrapping_key, .unwrap);

    const bytes = try cryptBytes(algo, unwrapping_key, wrapped_key, .unwrap, exec);
    const key_data: algorithm.KeyData = if (std.mem.eql(u8, format, "jwk"))
        .{ .jwk = try parseJwk(bytes, exec) }
    else
        .{ .bytes = .{ .values = bytes } };
    // importKey rejects a secret or private key with no usages (SyntaxError),
    // the last check unwrapKey asks for.
    return importNormalized(format, key_data, unwrapped_key_algo, extractable, key_usages, exec);
}

/// A KeyFormat, including the raw-* ones of the Modern Algorithms draft (see
/// rawAlias for the ones supported here). Any other string fails the WebIDL
/// enum conversion of the format argument, a TypeError before any other step.
fn checkFormat(format: []const u8, local: *const js.Local) !void {
    const formats = [_][]const u8{ "raw", "spki", "pkcs8", "jwk", "raw-public", "raw-private", "raw-seed", "raw-secret" };
    for (formats) |known| {
        if (std.mem.eql(u8, format, known)) {
            return;
        }
    }
    return local.typeError("invalid key format");
}

/// A BufferSource argument taken as a value. Its type is checked when the
/// operation is called (a TypeError, as WebIDL's conversion gives), but its
/// bytes are read with `bufferBytes` only once the algorithm is normalized:
/// normalizing runs the page's getters, which can transfer the buffer, and
/// its bytes must then read as the now-empty buffer rather than through a
/// pointer into a moved backing store.
///
/// None of SubtleCrypto's BufferSource arguments is [AllowShared]: a
/// SharedArrayBuffer, or a view onto one, is a TypeError.
fn checkBufferSource(value: js.Value, local: *const js.Local) !void {
    if (!value.isBufferSource()) {
        return local.typeError("expected an ArrayBuffer or ArrayBufferView");
    }
}

fn bufferBytes(value: js.Value, local: *const js.Local) ![]const u8 {
    const buffer = local.jsValueToZig(js.BufferSource, value) catch |err| {
        return algorithm.conversionError(err, local, "expected an ArrayBuffer or ArrayBufferView");
    };
    return buffer.bytes;
}

/// What `cryptBytes` is for, which decides the direction and the usage the key
/// needs.
const CryptUse = enum {
    encrypt,
    decrypt,
    wrap,
    unwrap,

    fn encrypting(self: CryptUse) bool {
        return self == .encrypt or self == .wrap;
    }

    fn usage(self: CryptUse) u8 {
        return switch (self) {
            .encrypt => CryptoKey.Usages.encrypt,
            .decrypt => CryptoKey.Usages.decrypt,
            .wrap => CryptoKey.Usages.wrapKey,
            .unwrap => CryptoKey.Usages.unwrapKey,
        };
    }
};

/// The checks wrapKey/unwrapKey make on the wrapping key before touching the
/// other key, in the spec's order: the same algorithm as the wrapping key, and
/// the wrapKey/unwrapKey usage.
fn checkWrappingKey(name: []const u8, wrapping_key: *const CryptoKey, use: CryptUse) !void {
    if (!eqlIgnoreCase(name, wrapping_key._algorithm.name)) {
        return error.InvalidAccessError;
    }
    if (wrapping_key._usages & use.usage() == 0) {
        return error.InvalidAccessError;
    }
}

/// "Parse a JWK" for unwrapKey: the bytes as JSON text, converted to a JWK the
/// way an importKey `keyData` object is. Anything that doesn't parse is
/// DataError; the import then rejects what isn't a usable JWK.
fn parseJwk(bytes: []const u8, exec: *const Execution) !algorithm.KeyData.Jwk {
    const local = exec.js.local.?;
    // JSON.parse throws on bad input: keep that exception from the page.
    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const value = local.parseJSON(bytes) catch return error.DataError;
    return local.jsValueToZig(algorithm.KeyData.Jwk, value) catch return error.DataError;
}

/// Encrypts or decrypts `data` with `key`, for encrypt/decrypt and for
/// wrapKey/unwrapKey, which encrypt the exported key (or use AES-KW's own key
/// wrap). Returns the resulting bytes.
fn cryptBytes(
    algo: algorithm.Encrypt,
    key: *CryptoKey,
    data: []const u8,
    use: CryptUse,
    exec: *const Execution,
) ![]const u8 {
    switch (algo) {
        .rsa_oaep => |p| {
            const label: []const u8 = if (p.label) |l| l.values else "";
            return RSA.crypt(key, data, label, use.encrypting(), use.usage(), exec);
        },
        // AES-KW has no encrypt/decrypt (fromJs only allows it for wrapping).
        .aes_kw => return AES.keyWrap(key, data, use.encrypting(), use.usage(), exec),
        .aes => |params| return AES.crypt(params, key, data, use.encrypting(), use.usage(), exec),
    }
}

/// Generate a digital signature.
pub fn sign(
    _: *const SubtleCrypto,
    /// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/sign#algorithm
    algo_value: js.Value,
    key: *CryptoKey,
    data_value: js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkBufferSource(data_value, local);
    const algo = try algorithm.Sign.fromJs(algo_value, local);
    const data = try bufferBytes(data_value, local);
    const hash_name = try algo.hashName(local);
    try checkSigningKey(algo.algoName(), key, CryptoKey.Usages.sign);
    const signature = switch (key._type) {
        .hmac => try HMAC.sign(key, data, exec),
        .rsa => try RSA.sign(key, data, algo.saltLength(), exec),
        .ec => try EC.sign(key, data, hash_name orelse return error.OperationError, exec),
        .ed25519 => try OKP.sign(key, data, exec),
        // A signing algorithm with no sign here yet (Ed448).
        else => {
            log.debug(.not_implemented, "SubtleCrypto.sign", .{ .key_type = key._type });
            return error.NotSupported;
        },
    };
    return local.resolvePromise(js.ArrayBuffer{ .values = signature });
}

/// Verify a digital signature.
pub fn verify(
    _: *const SubtleCrypto,
    algo_value: js.Value,
    key: *const CryptoKey,
    signature_value: js.Value,
    data_value: js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    try checkBufferSource(signature_value, local);
    try checkBufferSource(data_value, local);
    const algo = try algorithm.Sign.fromJs(algo_value, local);
    const signature = try bufferBytes(signature_value, local);
    const data = try bufferBytes(data_value, local);
    const hash_name = try algo.hashName(local);
    try checkSigningKey(algo.algoName(), key, CryptoKey.Usages.verify);
    const valid = switch (key._type) {
        .hmac => try HMAC.verify(key, signature, data),
        .rsa => try RSA.verify(key, signature, data, algo.saltLength()),
        .ec => try EC.verify(key, signature, data, hash_name orelse return error.OperationError),
        .ed25519 => try OKP.verify(key, signature, data),
        // A signing algorithm with no verify here yet (Ed448).
        else => {
            log.debug(.not_implemented, "SubtleCrypto.verify", .{ .key_type = key._type });
            return error.NotSupported;
        },
    };
    return local.resolvePromise(valid);
}

/// The checks sign/verify make after normalizing their algorithm, in the
/// spec's order: the key's own algorithm, and the sign or verify usage (else
/// InvalidAccessError). The names match case-insensitively, as normalization
/// does.
fn checkSigningKey(name: []const u8, key: *const CryptoKey, usage: u8) !void {
    if (!eqlIgnoreCase(name, key._algorithm.name)) {
        return error.InvalidAccessError;
    }
    if (key._usages & usage == 0) {
        return error.InvalidAccessError;
    }
}

/// `digest()` accepts an AlgorithmIdentifier: either a bare string (`"SHA-256"`)
/// or an object (`{name: "SHA-256"}`). The object variant must come first — a
/// `[]const u8` coerces *any* JS value to a string, so it has to be the fallback.
const DigestInput = union(enum) {
    obj: struct { name: ?[]const u8 = null },
    str: []const u8,

    fn name(self: DigestInput) ?[]const u8 {
        return switch (self) {
            .obj => |o| o.name,
            .str => |s| s,
        };
    }
};

/// Generates a digest of the given data, using the specified hash function.
pub fn digest(_: *const SubtleCrypto, algo: DigestInput, data: js.BufferSource, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const algo_name = algo.name() orelse {
        return local.typeError(missing_name);
    };
    if (algo_name.len > 10) {
        return error.NotSupported;
    }

    const normalized = try std.ascii.allocUpperString(exec.local_arena, algo_name);
    const digest_type = crypto.findDigest(normalized) catch return error.NotSupported;

    const bytes = data.bytes;
    var out: [crypto.EVP_MAX_MD_SIZE]u8 = undefined;
    var out_size: c_uint = 0;
    const result = crypto.EVP_Digest(bytes.ptr, bytes.len, &out, &out_size, digest_type, null);
    lp.assert(result == 1, "SubtleCrypto.digest", .{ .algo = algo });

    return local.resolvePromise(js.ArrayBuffer{ .values = out[0..out_size] });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SubtleCrypto);

    pub const Meta = struct {
        pub const name = "SubtleCrypto";

        pub var class_id: bridge.ClassId = undefined;
    };

    pub const generateKey = bridge.function(SubtleCrypto.generateKey, .{});
    pub const importKey = bridge.function(SubtleCrypto.importKey, .{});
    pub const exportKey = bridge.function(SubtleCrypto.exportKey, .{});
    pub const encrypt = bridge.function(SubtleCrypto.encrypt, .{});
    pub const decrypt = bridge.function(SubtleCrypto.decrypt, .{});
    pub const wrapKey = bridge.function(SubtleCrypto.wrapKey, .{});
    pub const unwrapKey = bridge.function(SubtleCrypto.unwrapKey, .{});
    pub const sign = bridge.function(SubtleCrypto.sign, .{});
    pub const verify = bridge.function(SubtleCrypto.verify, .{});
    pub const deriveBits = bridge.function(SubtleCrypto.deriveBits, .{});
    pub const deriveKey = bridge.function(SubtleCrypto.deriveKey, .{});
    pub const digest = bridge.function(SubtleCrypto.digest, .{});
};

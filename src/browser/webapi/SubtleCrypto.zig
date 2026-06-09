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
const common = @import("crypto/common.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;

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
    algo: algorithm.Init,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    switch (algo) {
        .hmac_key_gen => |params| return HMAC.init(params, extractable, key_usages, exec),
        .aes_key_gen => |params| return AES.generate(params, extractable, key_usages, exec),
        .ec_key_gen => |params| return EC.generate(params, extractable, key_usages, exec),
        .rsa_hashed_key_gen => |params| {
            RSA.validate(params, key_usages) catch |err| {
                return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
            };
            log.warn(.not_implemented, "generateKey", .{ .name = params.name });
        },
        .name => |js_name| return generateKeyFromName(try js_name.toSSO(false), extractable, key_usages, exec),
        .object => |object| return generateKeyFromName(try object.name.toSSO(false), extractable, key_usages, exec),
        .invalid => return local.rejectPromise(.{ .type_error = "invalid algorithm" }),
    }

    return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
}

fn generateKeyFromName(
    name: String,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    return _generateKeyFromName(name, extractable, key_usages, exec) catch |err| {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = err } });
    };
}

fn _generateKeyFromName(
    name: String,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    if (name.eql(comptime .wrap("X25519"))) {
        return X25519.init(extractable, key_usages, exec);
    }

    {
        // Algorithms whose `generateKey` parameters are just `{name}` — Ed25519,
        // Ed448, X448. Validates usages so failure-path tests get the spec-mandated
        // error name; leaves real key generation to a future change.

        const allowed: []const []const u8 = blk: {
            const str = name.str();
            if (eqlIgnoreCase(str, "Ed25519") or eqlIgnoreCase(str, "Ed448")) {
                break :blk &.{ "sign", "verify" };
            }
            if (eqlIgnoreCase(str, "X448")) {
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

    log.warn(.not_implemented, "generateKey", .{ .name = name });
    return error.NotSupported;
}

/// Imports a key from an external, portable format and returns a `CryptoKey`.
pub fn importKey(
    _: *const SubtleCrypto,
    format: []const u8,
    key_data: algorithm.KeyData,
    algo: algorithm.Import,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const name = algo.algoName();

    // Asymmetric algorithms (EC, OKP). Usage validation runs first (bad/empty
    // usages → SyntaxError) so the failure-path tests pass regardless of whether
    // the key material itself can be parsed yet.
    const is_private = importKind(format, key_data);
    if (asymmetricAllowedUsages(name, is_private)) |allowed| {
        // Public keys may have empty usages; secret/private keys may not.
        const mask = common.usageMaskInner(allowed, key_usages, is_private) catch |err| {
            return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
        };
        if (EC.canonicalName(name) != null) {
            const der = switch (key_data) {
                .bytes => |b| b.values,
                .jwk => return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } }),
            };
            return EC.import(name, algo.namedCurve(), format, der, is_private, extractable, mask, exec);
        }
        log.warn(.not_implemented, "SubtleCrypto.importKey", .{ .name = name });
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    // Resolve the raw key bytes from the requested format. Symmetric keys
    // support "raw" (a BufferSource) and "jwk" (an "oct" JSON Web Key).
    const raw: []const u8 = blk: {
        if (std.mem.eql(u8, format, "raw")) {
            break :blk switch (key_data) {
                .bytes => |b| b.values,
                // A JWK object passed where a BufferSource is expected.
                .jwk => return local.rejectPromise(.{ .type_error = "raw format expects a BufferSource" }),
            };
        }
        if (std.mem.eql(u8, format, "jwk")) {
            const jwk = switch (key_data) {
                .jwk => |j| j,
                .bytes => return local.rejectPromise(.{ .type_error = "jwk format expects an object" }),
            };
            if (!std.mem.eql(u8, jwk.kty, "oct")) {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            }
            const k = jwk.k orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
            break :blk common.base64Decode(exec.call_arena, k) catch |err| switch (err) {
                error.DataError => return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } }),
                else => |e| return e,
            };
        }
        // spki / pkcs8 (asymmetric formats) are not supported for these algorithms.
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };

    if (AES.canonicalName(name) != null) {
        return AES.import(name, raw, extractable, key_usages, exec);
    }

    // HKDF / PBKDF2: key-derivation inputs. The raw bytes are the key; there's
    // no length constraint and these keys are non-extractable.
    inline for ([_][]const u8{ "HKDF", "PBKDF2" }) |derive_name| {
        if (eqlIgnoreCase(name, derive_name)) {
            const mask = common.usageMask(&.{ "deriveKey", "deriveBits" }, key_usages) catch |err| {
                return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
            };
            const key = try exec.arena.dupe(u8, raw);
            const crypto_key = try exec._factory.create(CryptoKey{
                ._type = .derive,
                ._kind = .secret,
                ._extractable = extractable,
                ._usages = mask,
                ._key = key,
                ._algorithm = .{ .name = derive_name },
            });
            return local.resolvePromise(crypto_key);
        }
    }
    if (eqlIgnoreCase(name, "HMAC")) {
        const hash_name = switch (algo) {
            .hmac => |h| switch (h.hash) {
                .string => |s| s,
                .object => |o| o.name,
            },
            else => return local.rejectPromise(.{ .type_error = "HMAC import requires a hash" }),
        };
        return HMAC.import(hash_name, raw, extractable, key_usages, exec);
    }

    log.warn(.not_implemented, "SubtleCrypto.importKey", .{ .name = name });
    return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
}

/// Whether the requested format/key-data describe a private key. The format
/// alone decides for DER/raw variants; for JWK the presence of `d` marks it.
fn importKind(format: []const u8, key_data: algorithm.KeyData) bool {
    if (eqlIgnoreCase(format, "pkcs8") or eqlIgnoreCase(format, "raw-private") or eqlIgnoreCase(format, "raw-seed")) {
        return true;
    }
    if (eqlIgnoreCase(format, "jwk")) {
        return switch (key_data) {
            .jwk => |j| j.d != null,
            .bytes => false,
        };
    }
    // spki, raw, raw-public, ...
    return false;
}

/// The usages permitted for an EC/OKP key of the given privacy, or null if the
/// algorithm isn't one of the asymmetric algorithms handled here. Real key
/// import for these isn't implemented yet — this only drives usage validation.
fn asymmetricAllowedUsages(name: []const u8, is_private: bool) ?[]const []const u8 {
    if (eqlIgnoreCase(name, "ECDSA") or eqlIgnoreCase(name, "Ed25519") or eqlIgnoreCase(name, "Ed448")) {
        return if (is_private) &.{"sign"} else &.{"verify"};
    }
    if (eqlIgnoreCase(name, "ECDH") or eqlIgnoreCase(name, "X25519") or eqlIgnoreCase(name, "X448")) {
        return if (is_private) &.{ "deriveKey", "deriveBits" } else &.{};
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
    if (!key.canExportKey()) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } });
    }

    if (std.mem.eql(u8, format, "raw")) {
        return local.resolvePromise(js.ArrayBuffer{ .values = key._key });
    }

    if (std.mem.eql(u8, format, "jwk")) {
        return exportJwk(key, exec);
    }

    const is_unsupported = std.mem.eql(u8, format, "pkcs8") or std.mem.eql(u8, format, "spki");
    if (is_unsupported) {
        log.warn(.not_implemented, "SubtleCrypto.exportKey", .{ .format = format });
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    return local.rejectPromise(.{ .type_error = "invalid format" });
}

/// The JSON Web Key returned for symmetric ("oct") keys.
const JwkSecret = struct {
    kty: []const u8 = "oct",
    k: []const u8,
    alg: []const u8,
    ext: bool,
    key_ops: []const []const u8,
};

fn exportJwk(key: *CryptoKey, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    // The `alg` registry value depends on the algorithm and key length.
    const alg: []const u8 = switch (key._type) {
        .aes => try std.fmt.allocPrint(exec.call_arena, "A{d}{s}", .{
            key._key.len * 8,
            key._algorithm.name[4..], // strip "AES-"
        }),
        .hmac => blk: {
            const hash: []const u8 = key._algorithm.hash orelse "SHA-";
            break :blk try std.fmt.allocPrint(exec.call_arena, "HS{s}", .{hash[4..]}); // strip "SHA-"
        },
        else => {
            log.warn(.not_implemented, "SubtleCrypto.exportKey", .{ .format = "jwk", .type = key._type });
            return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
        },
    };

    return local.resolvePromise(JwkSecret{
        .k = try common.base64Encode(exec.call_arena, key._key),
        .alg = alg,
        .ext = key._extractable,
        .key_ops = try key.getUsages(exec),
    });
}

/// Derive an array of bits from a base key. `length` is in bits and may be null
/// (the WebIDL type is `unsigned long?`).
pub fn deriveBits(
    _: *const SubtleCrypto,
    algo: algorithm.Derive,
    base_key: *const CryptoKey,
    length: ?u32,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const bits = deriveRaw(algo, base_key, length, base_key.canDeriveBits(), exec) catch |err| {
        return rejectDerive(local, err);
    };
    return local.resolvePromise(js.ArrayBuffer{ .values = bits });
}

/// Derive a new CryptoKey from a base key: derive the right number of bits for
/// `derived`, then import them as that key type.
pub fn deriveKey(
    _: *const SubtleCrypto,
    algo: algorithm.Derive,
    base_key: *const CryptoKey,
    derived: algorithm.DerivedKey,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    // The base key's deriveKey usage (not deriveBits) gates this operation.
    const usage_ok = base_key.canDeriveKey();

    switch (derived) {
        .keyed => |k| {
            if (AES.canonicalName(k.name) == null) {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
            }
            const bits = deriveRaw(algo, base_key, k.length, usage_ok, exec) catch |err| {
                return rejectDerive(local, err);
            };
            return AES.import(k.name, bits, extractable, key_usages, exec);
        },
        .hmac => |h| {
            const hash_name = h.hash.name();
            const hash_md = crypto.findDigest(hash_name) catch {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
            };
            // Default length, per spec, is the hash's block size (in bits).
            const length: u32 = h.length orelse @intCast(crypto.EVP_MD_block_size(hash_md) * 8);
            const bits = deriveRaw(algo, base_key, length, usage_ok, exec) catch |err| {
                return rejectDerive(local, err);
            };
            return HMAC.import(hash_name, bits, extractable, key_usages, exec);
        },
        .object, .name => {
            log.warn(.not_implemented, "SubtleCrypto.deriveKey", .{});
            return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
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
                // null length means "derive the full shared secret" (256 bits).
                const result = X25519.deriveBits(base_key, params.public, length orelse 256, exec) catch |err| switch (err) {
                    error.InvalidAccessError => return error.InvalidAccessError,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.OperationError,
                };
                return result.values;
            }
            if (eqlIgnoreCase(params.name, "ECDH")) {
                return EC.deriveBits(base_key, params.public, length, exec);
            }
            return error.NotSupported;
        },
    }
}

/// Maps a KDF error to the spec-mandated DOMException (OutOfMemory propagates).
fn rejectDerive(local: *const js.Local, err: KDF.Error) !js.Promise {
    return switch (err) {
        error.InvalidAccessError => local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } }),
        error.NotSupported => local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } }),
        error.OperationError => local.rejectPromise(.{ .dom_exception = .{ .err = error.OperationError } }),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Encrypts data with the given key and algorithm.
pub fn encrypt(
    _: *const SubtleCrypto,
    algo: algorithm.Encrypt,
    key: *CryptoKey,
    data: js.TypedArray(u8),
    exec: *const Execution,
) !js.Promise {
    return cryptOp(algo, key, data.values, true, exec);
}

/// Decrypts data with the given key and algorithm.
pub fn decrypt(
    _: *const SubtleCrypto,
    algo: algorithm.Encrypt,
    key: *CryptoKey,
    data: js.TypedArray(u8),
    exec: *const Execution,
) !js.Promise {
    return cryptOp(algo, key, data.values, false, exec);
}

fn cryptOp(
    algo: algorithm.Encrypt,
    key: *CryptoKey,
    data: []const u8,
    encrypting: bool,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    const params = switch (algo) {
        .params => |p| p,
        // A bare string identifier carries no iv/counter, so it can't drive AES.
        .name => return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } }),
    };

    const out = AES.crypt(params, key, data, encrypting, exec) catch |err| switch (err) {
        error.InvalidAccessError => return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } }),
        error.OperationError => return local.rejectPromise(.{ .dom_exception = .{ .err = error.OperationError } }),
        error.NotSupported => return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } }),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return local.resolvePromise(js.ArrayBuffer{ .values = out });
}

/// Generate a digital signature.
pub fn sign(
    _: *const SubtleCrypto,
    /// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/sign#algorithm
    algo: algorithm.Sign,
    key: *CryptoKey,
    data: []const u8, // ArrayBuffer.
    exec: *const Execution,
) !js.Promise {
    return switch (key._type) {
        // Call sign for HMAC.
        .hmac => return HMAC.sign(algo, key, data, exec),
        else => {
            log.warn(.not_implemented, "SubtleCrypto.sign", .{ .key_type = key._type });
            return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } });
        },
    };
}

/// Verify a digital signature.
pub fn verify(
    _: *const SubtleCrypto,
    algo: algorithm.Sign,
    key: *const CryptoKey,
    signature: []const u8, // ArrayBuffer.
    data: []const u8, // ArrayBuffer.
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    if (!algo.isHMAC()) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } });
    }

    return switch (key._type) {
        .hmac => HMAC.verify(key, signature, data, exec),
        else => local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } }),
    };
}

/// `digest()` accepts an AlgorithmIdentifier: either a bare string (`"SHA-256"`)
/// or an object (`{name: "SHA-256"}`). The object variant must come first — a
/// `[]const u8` coerces *any* JS value to a string, so it has to be the fallback.
const DigestInput = union(enum) {
    obj: struct { name: []const u8 },
    str: []const u8,

    fn name(self: DigestInput) []const u8 {
        return switch (self) {
            .obj => |o| o.name,
            .str => |s| s,
        };
    }
};

/// Generates a digest of the given data, using the specified hash function.
pub fn digest(_: *const SubtleCrypto, algo: DigestInput, data: js.TypedArray(u8), exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const algo_name = algo.name();
    if (algo_name.len > 10) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    const normalized = std.ascii.upperString(exec.buf, algo_name);
    const digest_type = crypto.findDigest(normalized) catch {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };

    const bytes = data.values;
    const out = exec.buf[0..crypto.EVP_MAX_MD_SIZE];
    var out_size: c_uint = 0;
    const result = crypto.EVP_Digest(bytes.ptr, bytes.len, out, &out_size, digest_type, null);
    lp.assert(result == 1, "SubtleCrypto.digest", .{ .algo = algo });

    return local.resolvePromise(js.ArrayBuffer{ .values = out[0..out_size] });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SubtleCrypto);

    pub const Meta = struct {
        pub const name = "SubtleCrypto";

        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const generateKey = bridge.function(SubtleCrypto.generateKey, .{ .dom_exception = true });
    pub const importKey = bridge.function(SubtleCrypto.importKey, .{ .dom_exception = true });
    pub const exportKey = bridge.function(SubtleCrypto.exportKey, .{ .dom_exception = true });
    pub const encrypt = bridge.function(SubtleCrypto.encrypt, .{ .dom_exception = true });
    pub const decrypt = bridge.function(SubtleCrypto.decrypt, .{ .dom_exception = true });
    pub const sign = bridge.function(SubtleCrypto.sign, .{ .dom_exception = true });
    pub const verify = bridge.function(SubtleCrypto.verify, .{ .dom_exception = true });
    pub const deriveBits = bridge.function(SubtleCrypto.deriveBits, .{ .dom_exception = true });
    pub const deriveKey = bridge.function(SubtleCrypto.deriveKey, .{ .dom_exception = true });
    pub const digest = bridge.function(SubtleCrypto.digest, .{ .dom_exception = true });
};

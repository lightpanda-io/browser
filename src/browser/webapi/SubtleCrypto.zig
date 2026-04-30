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

const Frame = @import("../Frame.zig");
const js = @import("../js/js.zig");

const CryptoKey = @import("CryptoKey.zig");

const algorithm = @import("crypto/algorithm.zig");
const AES = @import("crypto/AES.zig");
const EC = @import("crypto/EC.zig");
const HMAC = @import("crypto/HMAC.zig");
const RSA = @import("crypto/RSA.zig");
const X25519 = @import("crypto/X25519.zig");

const log = lp.log;
const String = lp.String;

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
    frame: *Frame,
) !js.Promise {
    const local = frame.js.local.?;
    switch (algo) {
        .hmac_key_gen => |params| return HMAC.init(params, extractable, key_usages, frame),
        .aes_key_gen => |params| {
            AES.validate(params, key_usages) catch |err| {
                return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
            };
            log.warn(.not_implemented, "generateKey", .{ .name = params.name });
        },
        .ec_key_gen => |params| {
            EC.validate(params, key_usages) catch |err| {
                return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
            };
            log.warn(.not_implemented, "generateKey", .{ .name = params.name });
        },
        .rsa_hashed_key_gen => |params| {
            RSA.validate(params, key_usages) catch |err| {
                return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
            };
            log.warn(.not_implemented, "generateKey", .{ .name = params.name });
        },
        .name => |js_name| return generateKeyFromName(try js_name.toSSO(false), extractable, key_usages, frame),
        .object => |object| return generateKeyFromName(try object.name.toSSO(false), extractable, key_usages, frame),
        .invalid => return local.rejectPromise(.{ .type_error = "invalid algorithm" }),
    }

    return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
}

fn generateKeyFromName(
    name: String,
    extractable: bool,
    key_usages: []const []const u8,
    frame: *Frame,
) !js.Promise {
    return _generateKeyFromName(name, extractable, key_usages, frame) catch |err| {
        return frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = err } });
    };
}

fn _generateKeyFromName(
    name: String,
    extractable: bool,
    key_usages: []const []const u8,
    frame: *Frame,
) !js.Promise {
    if (name.eql(comptime .wrap("X25519"))) {
        return X25519.init(extractable, key_usages, frame);
    }

    {
        // Algorithms whose `generateKey` parameters are just `{name}` — Ed25519,
        // Ed448, X448. Validates usages so failure-path tests get the spec-mandated
        // error name; leaves real key generation to a future change.

        const allowed: []const []const u8 = blk: {
            const str = name.str();
            if (std.ascii.eqlIgnoreCase(str, "Ed25519") or std.ascii.eqlIgnoreCase(str, "Ed448")) {
                break :blk &.{ "sign", "verify" };
            }
            if (std.ascii.eqlIgnoreCase(str, "X448")) {
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

/// Exports a key: that is, it takes as input a CryptoKey object and gives you
/// the key in an external, portable format.
pub fn exportKey(
    _: *const SubtleCrypto,
    format: []const u8,
    key: *CryptoKey,
    frame: *Frame,
) !js.Promise {
    if (!key.canExportKey()) {
        return frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } });
    }

    if (std.mem.eql(u8, format, "raw")) {
        return frame.js.local.?.resolvePromise(js.ArrayBuffer{ .values = key._key });
    }

    const is_unsupported = std.mem.eql(u8, format, "pkcs8") or
        std.mem.eql(u8, format, "spki") or std.mem.eql(u8, format, "jwk");

    if (is_unsupported) {
        log.warn(.not_implemented, "SubtleCrypto.exportKey", .{ .format = format });
        return frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    return frame.js.local.?.rejectPromise(.{ .type_error = "invalid format" });
}

/// Derive a secret key from a master key.
pub fn deriveBits(
    _: *const SubtleCrypto,
    algo: algorithm.Derive,
    base_key: *const CryptoKey, // Private key.
    length: usize,
    frame: *Frame,
) !js.Promise {
    return switch (algo) {
        .ecdh_or_x25519 => |params| {
            const name = params.name;
            if (std.mem.eql(u8, name, "X25519")) {
                const result = X25519.deriveBits(base_key, params.public, length, frame) catch |err| switch (err) {
                    error.InvalidAccessError => return frame.js.local.?.rejectPromise(.{
                        .dom_exception = .{ .err = error.InvalidAccessError },
                    }),
                    else => return err,
                };

                return frame.js.local.?.resolvePromise(result);
            }

            if (std.mem.eql(u8, name, "ECDH")) {
                log.warn(.not_implemented, "SubtleCrypto.deriveBits", .{ .name = name });
            }

            return frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
        },
    };
}

/// Generate a digital signature.
pub fn sign(
    _: *const SubtleCrypto,
    /// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/sign#algorithm
    algo: algorithm.Sign,
    key: *CryptoKey,
    data: []const u8, // ArrayBuffer.
    frame: *Frame,
) !js.Promise {
    return switch (key._type) {
        // Call sign for HMAC.
        .hmac => return HMAC.sign(algo, key, data, frame),
        else => {
            log.warn(.not_implemented, "SubtleCrypto.sign", .{ .key_type = key._type });
            return frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } });
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
    frame: *Frame,
) !js.Promise {
    if (!algo.isHMAC()) {
        return frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } });
    }

    return switch (key._type) {
        .hmac => HMAC.verify(key, signature, data, frame),
        else => frame.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidAccessError } }),
    };
}

/// Generates a digest of the given data, using the specified hash function.
pub fn digest(_: *const SubtleCrypto, algo: []const u8, data: js.TypedArray(u8), frame: *Frame) !js.Promise {
    const local = frame.js.local.?;

    if (algo.len > 10) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    const normalized = std.ascii.upperString(&frame.buf, algo);
    const digest_type = crypto.findDigest(normalized) catch {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };

    const bytes = data.values;
    const out = frame.buf[0..crypto.EVP_MAX_MD_SIZE];
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
    pub const exportKey = bridge.function(SubtleCrypto.exportKey, .{ .dom_exception = true });
    pub const sign = bridge.function(SubtleCrypto.sign, .{ .dom_exception = true });
    pub const verify = bridge.function(SubtleCrypto.verify, .{ .dom_exception = true });
    pub const deriveBits = bridge.function(SubtleCrypto.deriveBits, .{ .dom_exception = true });
    pub const digest = bridge.function(SubtleCrypto.digest, .{ .dom_exception = true });
};

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const log = @import("../../log.zig");

const crypto = @import("../../crypto.zig");

const Page = @import("../Page.zig");
const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{ SubtleCrypto, CryptoKey };
}

/// The SubtleCrypto interface of the Web Crypto API provides a number of low-level
/// cryptographic functions.
/// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto
/// https://w3c.github.io/webcrypto/#subtlecrypto-interface
const SubtleCrypto = @This();
/// Don't optimize away the type.
_pad: bool = false,

const Algorithm = union(enum) {
    /// For RSASSA-PKCS1-v1_5, RSA-PSS, or RSA-OAEP: pass an RsaHashedKeyGenParams object.
    rsa_hashed_key_gen: RsaHashedKeyGen,
    /// For HMAC: pass an HmacKeyGenParams object.
    hmac_key_gen: HmacKeyGen,
    /// Can be Ed25519 or X25519.
    name: []const u8,
    /// Can be Ed25519 or X25519.
    object: struct { name: []const u8 },

    /// https://developer.mozilla.org/en-US/docs/Web/API/RsaHashedKeyGenParams
    const RsaHashedKeyGen = struct {
        name: []const u8,
        /// This should be at least 2048.
        /// Some organizations are now recommending that it should be 4096.
        modulusLength: u32,
        publicExponent: js.TypedArray(u8),
        hash: union(enum) {
            string: []const u8,
            object: struct { name: []const u8 },
        },
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/HmacKeyGenParams
    const HmacKeyGen = struct {
        /// Always HMAC.
        name: []const u8,
        /// Its also possible to pass this in an object.
        hash: union(enum) {
            string: []const u8,
            object: struct { name: []const u8 },
        },
        /// If omitted, default is the block size of the chosen hash function.
        length: ?usize,
    };
    /// Alias.
    const HmacImport = HmacKeyGen;

    const EcdhKeyDeriveParams = struct {
        /// Can be Ed25519 or X25519.
        name: []const u8,
        public: *const CryptoKey,
    };

    /// Algorithm for deriveBits() and deriveKey().
    const DeriveBits = union(enum) {
        ecdh_or_x25519: EcdhKeyDeriveParams,
    };
};

/// Generate a new key (for symmetric algorithms) or key pair (for public-key algorithms).
pub fn generateKey(
    _: *const SubtleCrypto,
    algorithm: Algorithm,
    extractable: bool,
    key_usages: []const []const u8,
    page: *Page,
) !js.Promise {
    const key_or_pair = CryptoKey.init(algorithm, extractable, key_usages, page) catch |err| {
        return page.js.rejectPromise(@errorName(err));
    };

    return page.js.resolvePromise(key_or_pair);
}

/// Exports a key: that is, it takes as input a CryptoKey object and gives you
/// the key in an external, portable format.
pub fn exportKey(
    _: *const SubtleCrypto,
    format: []const u8,
    key: *CryptoKey,
    page: *Page,
) !js.Promise {
    if (!key.canExportKey()) {
        return error.InvalidAccessError;
    }

    if (std.mem.eql(u8, format, "raw")) {
        return page.js.resolvePromise(js.ArrayBuffer{ .values = key._key });
    }

    const is_unsupported = std.mem.eql(u8, format, "pkcs8") or
        std.mem.eql(u8, format, "spki") or std.mem.eql(u8, format, "jwk");

    if (is_unsupported) {
        log.warn(.not_implemented, "SubtleCrypto.exportKey", .{ .format = format });
    }

    return page.js.rejectPromise(@errorName(error.NotSupported));
}

/// Derive a secret key from a master key.
pub fn deriveBits(
    _: *const SubtleCrypto,
    algorithm: Algorithm.DeriveBits,
    base_key: *const CryptoKey, // Private key.
    length: usize,
    page: *Page,
) !js.Promise {
    return switch (algorithm) {
        .ecdh_or_x25519 => |p| {
            const name = p.name;
            if (std.mem.eql(u8, name, "X25519")) {
                return page.js.resolvePromise(base_key.deriveBitsX25519(p.public, length, page));
            }

            if (std.mem.eql(u8, name, "ECDH")) {
                log.warn(.not_implemented, "SubtleCrypto.deriveBits", .{ .name = name });
            }

            return page.js.rejectPromise(@errorName(error.NotSupported));
        },
    };
}

const SignatureAlgorithm = union(enum) {
    string: []const u8,
    object: struct { name: []const u8 },

    pub fn isHMAC(self: SignatureAlgorithm) bool {
        const name = switch (self) {
            .string => |string| string,
            .object => |object| object.name,
        };

        if (name.len < 4) return false;
        const hmac: u32 = @bitCast([4]u8{ 'H', 'M', 'A', 'C' });
        return @as(u32, @bitCast(name[0..4].*)) == hmac;
    }
};

/// Generate a digital signature.
pub fn sign(
    _: *const SubtleCrypto,
    /// This can either be provided as string or object.
    /// We can't use the `Algorithm` type defined before though since there
    /// are couple of changes between the two.
    /// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/sign#algorithm
    algorithm: SignatureAlgorithm,
    key: *CryptoKey,
    data: []const u8, // ArrayBuffer.
    page: *Page,
) !js.Promise {
    return switch (key._type) {
        .hmac => {
            // Verify algorithm.
            if (!algorithm.isHMAC()) {
                return page.js.rejectPromise(@errorName(error.InvalidAccessError));
            }

            // Call sign for HMAC.
            const result = key.signHMAC(data, page) catch |err| {
                return page.js.rejectPromise(@errorName(err));
            };

            return page.js.resolvePromise(result);
        },
        else => {
            log.warn(.not_implemented, "SubtleCrypto.sign", .{ .key_type = key._type });
            return page.js.rejectPromise(@errorName(error.InvalidAccessError));
        },
    };
}

/// Verify a digital signature.
pub fn verify(
    _: *const SubtleCrypto,
    algorithm: SignatureAlgorithm,
    key: *const CryptoKey,
    signature: []const u8, // ArrayBuffer.
    data: []const u8, // ArrayBuffer.
    page: *Page,
) !js.Promise {
    if (!algorithm.isHMAC()) return error.InvalidAccessError;

    return switch (key._type) {
        .hmac => key.verifyHMAC(signature, data, page),
        else => return error.InvalidAccessError,
    };
}

/// Returns the desired digest by its name.
fn findDigest(name: []const u8) error{Invalid}!*const crypto.EVP_MD {
    if (std.mem.eql(u8, "SHA-256", name)) {
        return crypto.EVP_sha256();
    }

    if (std.mem.eql(u8, "SHA-384", name)) {
        return crypto.EVP_sha384();
    }

    if (std.mem.eql(u8, "SHA-512", name)) {
        return crypto.EVP_sha512();
    }

    if (std.mem.eql(u8, "SHA-1", name)) {
        return crypto.EVP_sha1();
    }

    return error.Invalid;
}

const KeyOrPair = union(enum) { key: *CryptoKey, pair: CryptoKeyPair };

/// https://developer.mozilla.org/en-US/docs/Web/API/CryptoKeyPair
const CryptoKeyPair = struct {
    privateKey: *CryptoKey,
    publicKey: *CryptoKey,
};

/// Represents a cryptographic key obtained from one of the SubtleCrypto methods
/// generateKey(), deriveKey(), importKey(), or unwrapKey().
pub const CryptoKey = struct {
    /// Algorithm being used.
    _type: Type,
    /// Whether the key is extractable.
    _extractable: bool,
    /// Bit flags of `usages`; see `Usages` type.
    _usages: u8,
    /// Raw bytes of key.
    _key: []const u8,
    /// Different algorithms may use different data structures;
    /// this union can be used for such situations. Active field is understood
    /// from `_type`.
    _vary: extern union {
        /// Used by HMAC.
        digest: *const crypto.EVP_MD,
        /// Used by asymmetric algorithms (X25519, Ed25519).
        pkey: *crypto.EVP_PKEY,
    },

    pub const Type = enum(u8) { hmac, rsa, x25519 };

    /// Changing the names of fields would affect bitmask creation.
    pub const Usages = struct {
        // zig fmt: off
        pub const encrypt    = 0x001;
        pub const decrypt    = 0x002;
        pub const sign       = 0x004;
        pub const verify     = 0x008;
        pub const deriveKey  = 0x010;
        pub const deriveBits = 0x020;
        pub const wrapKey    = 0x040;
        pub const unwrapKey  = 0x080;
        // zig fmt: on
    };

    pub fn init(
        algorithm: Algorithm,
        extractable: bool,
        key_usages: []const []const u8,
        page: *Page,
    ) !KeyOrPair {
        return switch (algorithm) {
            .hmac_key_gen => |hmac| initHMAC(hmac, extractable, key_usages, page),
            .name => |name| {
                if (std.mem.eql(u8, "X25519", name)) {
                    return initX25519(extractable, key_usages, page);
                }
                log.warn(.not_implemented, "CryptoKey.init", .{ .name = name });
                return error.NotSupported;
            },
            .object => |object| {
                // Ditto.
                const name = object.name;
                if (std.mem.eql(u8, "X25519", name)) {
                    return initX25519(extractable, key_usages, page);
                }
                log.warn(.not_implemented, "CryptoKey.init", .{ .name = name });
                return error.NotSupported;
            },
            else => {
                log.warn(.not_implemented, "CryptoKey.init", .{ .algorithm = algorithm });
                return error.NotSupported;
            },
        };
    }

    inline fn canSign(self: *const CryptoKey) bool {
        return self._usages & Usages.sign != 0;
    }

    inline fn canVerify(self: *const CryptoKey) bool {
        return self._usages & Usages.verify != 0;
    }

    inline fn canDeriveBits(self: *const CryptoKey) bool {
        return self._usages & Usages.deriveBits != 0;
    }

    inline fn canExportKey(self: *const CryptoKey) bool {
        return self._extractable;
    }

    /// Only valid for HMAC.
    inline fn getDigest(self: *const CryptoKey) *const crypto.EVP_MD {
        return self._vary.digest;
    }

    /// Only valid for asymmetric algorithms (X25519, Ed25519).
    inline fn getKeyObject(self: *const CryptoKey) *crypto.EVP_PKEY {
        return self._vary.pkey;
    }

    // HMAC.

    fn initHMAC(
        algorithm: Algorithm.HmacKeyGen,
        extractable: bool,
        key_usages: []const []const u8,
        page: *Page,
    ) !KeyOrPair {
        const hash = switch (algorithm.hash) {
            .string => |str| str,
            .object => |obj| obj.name,
        };
        // Find digest.
        const digest = try findDigest(hash);

        // We need at least a single usage.
        if (key_usages.len == 0) {
            return error.SyntaxError;
        }
        // Calculate usages mask.
        const decls = @typeInfo(Usages).@"struct".decls;
        var usages_mask: u8 = 0;
        iter_usages: for (key_usages) |usage| {
            inline for (decls) |decl| {
                if (std.mem.eql(u8, decl.name, usage)) {
                    usages_mask |= @field(Usages, decl.name);
                    continue :iter_usages;
                }
            }
            // Unknown usage if got here.
            return error.SyntaxError;
        }

        const block_size: usize = blk: {
            // Caller provides this in bits, not bytes.
            if (algorithm.length) |length| {
                break :blk length / 8;
            }
            // Prefer block size of the hash function instead.
            break :blk crypto.EVP_MD_block_size(digest);
        };

        const key = try page.arena.alloc(u8, block_size);
        errdefer page.arena.free(key);

        // HMAC is simply CSPRNG.
        const res = crypto.RAND_bytes(key.ptr, key.len);
        std.debug.assert(res == 1);

        const crypto_key = try page._factory.create(CryptoKey{
            ._type = .hmac,
            ._extractable = extractable,
            ._usages = usages_mask,
            ._key = key,
            ._vary = .{ .digest = digest },
        });

        return .{ .key = crypto_key };
    }

    fn signHMAC(self: *const CryptoKey, data: []const u8, page: *Page) !js.ArrayBuffer {
        if (!self.canSign()) {
            return error.InvalidAccessError;
        }

        const buffer = try page.call_arena.alloc(u8, crypto.EVP_MD_size(self.getDigest()));
        errdefer page.call_arena.free(buffer);
        var out_len: u32 = 0;
        // Try to sign.
        const signed = crypto.HMAC(
            self.getDigest(),
            @ptrCast(self._key.ptr),
            self._key.len,
            data.ptr,
            data.len,
            buffer.ptr,
            &out_len,
        );

        if (signed != null) {
            return js.ArrayBuffer{ .values = buffer[0..out_len] };
        }

        // Not DOM exception, failed on our side.
        return error.Invalid;
    }

    fn verifyHMAC(
        self: *const CryptoKey,
        signature: []const u8,
        data: []const u8,
        page: *Page,
    ) !js.Promise {
        if (!self.canVerify()) {
            return error.InvalidAccessError;
        }

        var buffer: [crypto.EVP_MAX_MD_BLOCK_SIZE]u8 = undefined;
        var out_len: u32 = 0;
        // Try to sign.
        const signed = crypto.HMAC(
            self.getDigest(),
            @ptrCast(self._key.ptr),
            self._key.len,
            data.ptr,
            data.len,
            &buffer,
            &out_len,
        );

        if (signed != null) {
            // CRYPTO_memcmp compare in constant time so prohibits time-based attacks.
            const res = crypto.CRYPTO_memcmp(signed, @ptrCast(signature.ptr), signature.len);
            return page.js.resolvePromise(res == 0);
        }

        return page.js.resolvePromise(false);
    }

    // X25519.

    /// Create a pair of X25519.
    fn initX25519(
        extractable: bool,
        key_usages: []const []const u8,
        page: *Page,
    ) !KeyOrPair {
        // This code has too many allocations here and there, might be nice to
        // gather them together with a single alloc call. Not sure if factory
        // pattern is suitable for it though.

        // Calculate usages; only matters for private key.
        // Only deriveKey() and deriveBits() be used for X25519.
        if (key_usages.len == 0) {
            return error.SyntaxError;
        }
        var mask: u8 = 0;
        iter_usages: for (key_usages) |usage| {
            inline for ([_][]const u8{ "deriveKey", "deriveBits" }) |name| {
                if (std.mem.eql(u8, name, usage)) {
                    mask |= @field(Usages, name);
                    continue :iter_usages;
                }
            }
            // Unknown usage if got here.
            return error.SyntaxError;
        }

        const public_value = try page.arena.alloc(u8, crypto.X25519_PUBLIC_VALUE_LEN);
        errdefer page.arena.free(public_value);

        const private_key = try page.arena.alloc(u8, crypto.X25519_PRIVATE_KEY_LEN);
        errdefer page.arena.free(private_key);

        // There's no info about whether this can fail; so I assume it cannot.
        crypto.X25519_keypair(@ptrCast(public_value), @ptrCast(private_key));

        // Create EVP_PKEY for public key.
        // Seems we can use `EVP_PKEY_from_raw_private_key` for this, Chrome
        // prefer not to, yet BoringSSL added it and recommends instead of what
        // we're doing currently.
        const public_pkey = crypto.EVP_PKEY_new_raw_public_key(
            crypto.EVP_PKEY_X25519,
            null,
            public_value.ptr,
            public_value.len,
        );
        if (public_pkey == null) {
            return error.OutOfMemory;
        }

        // Create EVP_PKEY for private key.
        // Seems we can use `EVP_PKEY_from_raw_private_key` for this, Chrome
        // prefer not to, yet BoringSSL added it and recommends instead of what
        // we're doing currently.
        const private_pkey = crypto.EVP_PKEY_new_raw_private_key(
            crypto.EVP_PKEY_X25519,
            null,
            private_key.ptr,
            private_key.len,
        );
        if (private_pkey == null) {
            return error.OutOfMemory;
        }

        const private = try page._factory.create(CryptoKey{
            ._type = .x25519,
            ._extractable = extractable,
            ._usages = mask,
            ._key = private_key,
            ._vary = .{ .pkey = private_pkey.? },
        });
        errdefer page._factory.destroy(private);

        const public = try page._factory.create(CryptoKey{
            ._type = .x25519,
            // Public keys are always extractable.
            ._extractable = true,
            // Always empty for public key.
            ._usages = 0,
            ._key = public_value,
            ._vary = .{ .pkey = public_pkey.? },
        });
        errdefer page._factory.destroy(public);

        return .{ .pair = .{ .privateKey = private, .publicKey = public } };
    }

    fn deriveBitsX25519(
        private: *const CryptoKey,
        public: *const CryptoKey,
        length_in_bits: usize,
        page: *Page,
    ) !js.ArrayBuffer {
        if (!private.canDeriveBits()) {
            return error.InvalidAccessError;
        }

        const maybe_ctx = crypto.EVP_PKEY_CTX_new(private.getKeyObject(), null);
        if (maybe_ctx) |ctx| {
            // Context is valid, free it on failure.
            errdefer crypto.EVP_PKEY_CTX_free(ctx);

            // Init derive operation and set public key as peer.
            if (crypto.EVP_PKEY_derive_init(ctx) != 1 or
                crypto.EVP_PKEY_derive_set_peer(ctx, public.getKeyObject()) != 1)
            {
                // Failed on our end.
                return error.Internal;
            }

            const derived_key = try page.call_arena.alloc(u8, 32);
            errdefer page.call_arena.free(derived_key);

            var out_key_len: usize = derived_key.len;
            const result = crypto.EVP_PKEY_derive(ctx, derived_key.ptr, &out_key_len);
            if (result != 1) {
                // Failed on our end.
                return error.Internal;
            }
            // Sanity check.
            std.debug.assert(derived_key.len == out_key_len);

            // Length is in bits, convert to byte length.
            const length = (length_in_bits / 8) + (7 + (length_in_bits % 8)) / 8;
            // Truncate the slice to specified length.
            // Same as `derived_key`.
            const tailored = blk: {
                if (length > derived_key.len) {
                    return error.LengthTooLong;
                }
                break :blk derived_key[0..length];
            };

            // Zero any "unused bits" in the final byte.
            const remainder_bits: u3 = @intCast(length_in_bits % 8);
            if (remainder_bits != 0) {
                tailored[tailored.len - 1] &= ~(@as(u8, 0xFF) >> remainder_bits);
            }

            return js.ArrayBuffer{ .values = tailored };
        }

        // Failed on our end.
        return error.Internal;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CryptoKey);

        pub const Meta = struct {
            pub const name = "CryptoKey";

            pub var class_id: bridge.ClassId = undefined;
            pub const prototype_chain = bridge.prototypeChain();
        };
    };
};

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
};

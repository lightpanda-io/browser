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

//! This file provides various arguments needed for crypto APIs.

const js = @import("../../js/js.zig");

const CryptoKey = @import("../CryptoKey.zig");

/// Passed for `generateKey()`.
pub const Init = union(enum) {
    /// For RSASSA-PKCS1-v1_5, RSA-PSS, or RSA-OAEP: pass an RsaHashedKeyGenParams object.
    rsa_hashed_key_gen: RsaHashedKeyGen,
    /// For HMAC: pass an HmacKeyGenParams object.
    hmac_key_gen: HmacKeyGen,
    /// For AES variants: pass an AesKeyGenParams object.
    aes_key_gen: AesKeyGen,
    /// For ECDSA / ECDH: pass an EcKeyGenParams object.
    ec_key_gen: EcKeyGen,

    /// don't use []const u8 here, we don't want non-strings coerced. Let those
    /// fall to the invalid case
    /// Can be Ed25519 or X25519.
    object: struct { name: js.String },
    /// Can be Ed25519 or X25519.
    name: js.String,

    invalid: js.Value,

    /// https://developer.mozilla.org/en-US/docs/Web/API/RsaHashedKeyGenParams
    pub const RsaHashedKeyGen = struct {
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

    /// https://developer.mozilla.org/en-US/docs/Web/API/AesKeyGenParams
    pub const AesKeyGen = struct {
        name: []const u8,
        length: u32,
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/EcKeyGenParams
    pub const EcKeyGen = struct {
        name: []const u8,
        namedCurve: []const u8,
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/HmacKeyGenParams
    pub const HmacKeyGen = struct {
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
    pub const HmacImport = HmacKeyGen;

    pub const EcdhKeyDeriveParams = struct {
        /// Can be Ed25519 or X25519.
        name: []const u8,
        public: *const CryptoKey,
    };
};

/// Algorithm for deriveBits() and deriveKey(). Variants are distinguished by
/// their required members (`iterations` for PBKDF2, `info` for HKDF, `public`
/// for ECDH/X25519), so probe order doesn't cause ambiguity.
pub const Derive = union(enum) {
    pbkdf2: Pbkdf2Params,
    hkdf: HkdfParams,
    ecdh_or_x25519: Init.EcdhKeyDeriveParams,

    /// A hash AlgorithmIdentifier — either `"SHA-256"` or `{name: "SHA-256"}`.
    pub const Hash = union(enum) {
        string: []const u8,
        object: struct { name: []const u8 },

        pub fn name(self: Hash) []const u8 {
            return switch (self) {
                .string => |s| s,
                .object => |o| o.name,
            };
        }
    };

    pub const Pbkdf2Params = struct {
        name: []const u8,
        hash: Hash,
        salt: js.TypedArray(u8),
        iterations: u32,
    };

    pub const HkdfParams = struct {
        name: []const u8,
        hash: Hash,
        salt: js.TypedArray(u8),
        info: js.TypedArray(u8),
    };
};

/// The `derivedKeyType` argument to `deriveKey()` — the algorithm of the key to
/// produce. HMAC carries a hash; AES carries a length. Probed in that order so
/// the more specific shapes win.
pub const DerivedKey = union(enum) {
    hmac: struct { name: []const u8, hash: Derive.Hash, length: ?u32 = null },
    keyed: struct { name: []const u8, length: u32 },
    object: struct { name: []const u8 },
    name: []const u8,
};

/// Algorithm passed to `importKey()`. HMAC carries a hash, so it must be probed
/// before the bare-`{name}` object; the plain string is the final fallback (any
/// JS value coerces to a string).
pub const Import = union(enum) {
    hmac: struct {
        name: []const u8,
        hash: union(enum) {
            string: []const u8,
            object: struct { name: []const u8 },
        },
        length: ?u32 = null,
    },
    ec: struct { name: []const u8, namedCurve: []const u8 },
    object: struct { name: []const u8 },
    name: []const u8,

    pub fn algoName(self: Import) []const u8 {
        return switch (self) {
            .hmac => |h| h.name,
            .ec => |e| e.name,
            .object => |o| o.name,
            .name => |n| n,
        };
    }

    /// The `namedCurve` if this is an EC import, else empty.
    pub fn namedCurve(self: Import) []const u8 {
        return switch (self) {
            .ec => |e| e.namedCurve,
            else => "",
        };
    }
};

/// Key material handed to `importKey()`: either a BufferSource (raw/spki/pkcs8)
/// or a JSON Web Key object (jwk). `bytes` is probed first — a JWK is a plain
/// object and won't coerce to a TypedArray.
pub const KeyData = union(enum) {
    bytes: js.TypedArray(u8),
    jwk: Jwk,

    /// Minimal JWK fields we read on import. Symmetric ("oct") keys only need
    /// `kty` and `k`; `d` marks an asymmetric private key. The rest are accepted
    /// for forward-compatibility.
    pub const Jwk = struct {
        kty: []const u8,
        k: ?[]const u8 = null,
        d: ?[]const u8 = null,
        alg: ?[]const u8 = null,
        use: ?[]const u8 = null,
        ext: ?bool = null,
    };
};

/// Algorithm for `encrypt()` / `decrypt()`. AES-CBC/CTR/GCM share one struct
/// (fields are mode-specific and optional) and dispatch on `name`; a bare string
/// is the fallback form.
pub const Encrypt = union(enum) {
    params: struct {
        name: []const u8,
        iv: ?js.TypedArray(u8) = null,
        counter: ?js.TypedArray(u8) = null,
        length: ?u32 = null,
        additionalData: ?js.TypedArray(u8) = null,
        tagLength: ?u32 = null,
    },
    name: []const u8,

    pub fn algoName(self: Encrypt) []const u8 {
        return switch (self) {
            .params => |p| p.name,
            .name => |n| n,
        };
    }
};

/// For `sign()` functionality.
pub const Sign = union(enum) {
    string: []const u8,
    object: struct { name: []const u8 },

    pub fn isHMAC(self: Sign) bool {
        const name = switch (self) {
            .string => |string| string,
            .object => |object| object.name,
        };

        if (name.len < 4) return false;
        const hmac: u32 = @bitCast([4]u8{ 'H', 'M', 'A', 'C' });
        return @as(u32, @bitCast(name[0..4].*)) == hmac;
    }
};

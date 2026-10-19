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

const std = @import("std");

const js = @import("../../js/js.zig");

const CryptoKey = @import("../CryptoKey.zig");
const common = @import("common.zig");

/// The TypeError of an algorithm identifier object without a `name`.
pub const missing_name = "required member name is undefined";

/// A HashAlgorithmIdentifier: either `"SHA-256"` or `{name: "SHA-256"}`. The
/// same conversion as any AlgorithmIdentifier's, which Derive reads its name
/// with.
pub const Hash = union(enum) {
    string: []const u8,
    object: struct { name: []const u8 },
    /// An object without a `name`: a TypeError, as for the algorithm itself.
    nameless: js.Object,

    pub fn name(self: Hash, local: *const js.Local) error{TypeError}![]const u8 {
        return switch (self) {
            .string => |s| s,
            .object => |o| o.name,
            .nameless => local.typeError(missing_name),
        };
    }

    /// The hash's registered name, matched case-insensitively: a TypeError
    /// without a name, NotSupportedError for a hash that isn't supported.
    pub fn canonical(self: Hash, local: *const js.Local) error{ TypeError, NotSupported }![]const u8 {
        return common.canonicalHash(try self.name(local)) orelse error.NotSupported;
    }
};

/// Passed for `generateKey()`.
pub const Init = union(enum) {
    /// For RSASSA-PKCS1-v1_5, RSA-PSS, or RSA-OAEP: pass an RsaHashedKeyGenParams object.
    rsa_hashed_key_gen: RsaHashedKeyGen,
    /// Must be before `hmac_key_gen`, since we need to ignore this param even
    /// if it has a 'hash' property, and if it's after, we'll match that instead.
    ec_key_gen: EcKeyGen,
    /// For HMAC: pass an HmacKeyGenParams object.
    hmac_key_gen: HmacKeyGen,
    /// For AES variants: pass an AesKeyGenParams object.
    aes_key_gen: AesKeyGen,

    /// don't use []const u8 here, we don't want non-strings coerced. Let those
    /// fall to the invalid case
    /// Can be Ed25519 or X25519.
    object: struct { name: js.String },
    /// Can be Ed25519 or X25519.
    name: js.String,

    invalid: js.Value,

    /// https://developer.mozilla.org/en-US/docs/Web/API/RsaHashedKeyGenParams
    pub const RsaHashedKeyGen = struct {
        hash: Hash,
        /// This should be at least 2048.
        /// Some organizations are now recommending that it should be 4096.
        /// An [EnforceRange] unsigned long, kept as a value: this dictionary
        /// is probed before the others, so converting it here would reject
        /// another algorithm's object that happens to carry one. RSA's
        /// generateKey converts it (RSA.modulusLength). It stays required, so
        /// an object without one is probed as the other dictionaries.
        modulusLength: js.Value,
        name: []const u8,
        publicExponent: js.TypedArray(u8),
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/AesKeyGenParams
    pub const AesKeyGen = struct {
        length: u32,
        name: []const u8,
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/EcKeyGenParams
    pub const EcKeyGen = struct {
        name: []const u8,
        namedCurve: []const u8,
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/HmacKeyGenParams
    pub const HmacKeyGen = struct {
        /// Its also possible to pass this in an object.
        hash: Hash,
        /// If omitted, default is the block size of the chosen hash function.
        /// An [EnforceRange] unsigned long, kept as a value: HMAC.init converts
        /// it (HMAC.lengthParam) once the name is known to be HMAC's, since
        /// another algorithm's object can be probed into this dictionary.
        length: ?js.Value = null,
        /// Always HMAC.
        name: []const u8,
    };
    const EcdhKeyDeriveParams = struct {
        /// ECDH or X25519.
        name: []const u8,
        public: *const CryptoKey,
    };
};

/// Algorithm for deriveBits() and deriveKey(), an AlgorithmIdentifier
/// normalized as the spec does: its name picks the algorithm (an unknown one
/// is NotSupportedError), then the value is converted to that algorithm's
/// params dictionary (a TypeError without a required member). Taken as a
/// js.Value, not probed by shape, so the name decides, not the members.
pub const Derive = union(enum) {
    pbkdf2: Pbkdf2Params,
    hkdf: HkdfParams,
    ecdh_or_x25519: Init.EcdhKeyDeriveParams,

    pub fn fromJs(value: js.Value, local: *const js.Local) !Derive {
        const identifier = try convert(Hash, value, local);
        const name = try identifier.name(local);
        if (std.ascii.eqlIgnoreCase(name, "PBKDF2")) {
            const params = try convert(Pbkdf2Params, value, local);
            _ = try params.hash.canonical(local);
            return .{ .pbkdf2 = params };
        }
        if (std.ascii.eqlIgnoreCase(name, "HKDF")) {
            const params = try convert(HkdfParams, value, local);
            _ = try params.hash.canonical(local);
            return .{ .hkdf = params };
        }
        if (std.ascii.eqlIgnoreCase(name, "ECDH") or std.ascii.eqlIgnoreCase(name, "X25519")) {
            return .{ .ecdh_or_x25519 = try convert(Init.EcdhKeyDeriveParams, value, local) };
        }
        return error.NotSupported;
    }

    /// `value` as `T`. A value that isn't one (a string for a dictionary, a
    /// missing member) is a TypeError; the page's own exception stays pending.
    fn convert(comptime T: type, value: js.Value, local: *const js.Local) !T {
        return local.jsValueToZig(T, value) catch |err| switch (err) {
            error.JsException, error.OutOfMemory => err,
            else => local.typeError("algorithm is missing a required member"),
        };
    }

    pub const Pbkdf2Params = struct {
        hash: Hash,
        /// An [EnforceRange] unsigned long: converted once the name is known
        /// to be PBKDF2's, so it's a TypeError out of range, not wrapped.
        iterations: js.EnforceRange(u32),
        name: []const u8,
        salt: js.TypedArray(u8),
    };

    pub const HkdfParams = struct {
        hash: Hash,
        info: js.TypedArray(u8),
        name: []const u8,
        salt: js.TypedArray(u8),
    };
};

/// The `derivedKeyType` argument to `deriveKey()` — the algorithm of the key to
/// produce. HMAC carries a hash; AES carries a length. Probed in that order so
/// the more specific shapes win.
pub const DerivedKey = union(enum) {
    /// `length` as in Import.hmac.
    hmac: struct { hash: Hash, length: ?js.Value = null, name: []const u8 },
    keyed: struct { length: u32, name: []const u8 },
    object: struct { name: []const u8 },
    /// An object without a `name`: a TypeError, as for every algorithm
    /// identifier. Probed before the string, which would coerce it.
    nameless: js.Object,
    name: []const u8,
};

/// Algorithm passed to `importKey()`. HMAC carries a hash, so it must be probed
/// before the bare-`{name}` object; the plain string is the final fallback (any
/// JS value coerces to a string).
pub const Import = union(enum) {
    hmac: struct {
        hash: Hash,
        /// HMAC's [EnforceRange] unsigned long, kept as a value: RSA imports
        /// share this variant and ignore it. HMAC.lengthParam converts it.
        length: ?js.Value = null,
        name: []const u8,
    },
    ec: struct { name: []const u8, namedCurve: []const u8 },
    object: struct { name: []const u8 },
    /// An object without a `name`: a TypeError, as for every algorithm
    /// identifier. Probed before the string, which would coerce it.
    nameless: js.Object,
    name: []const u8,

    /// Null for an object without a name.
    pub fn algoName(self: Import) ?[]const u8 {
        return switch (self) {
            .hmac => |h| h.name,
            .ec => |e| e.name,
            .object => |o| o.name,
            .nameless => null,
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

    /// The JWK fields we read on import. Symmetric ("oct") keys only need `kty`
    /// and `k`; `d` marks an asymmetric private key. RSA keys carry `n`/`e`
    /// (public) plus `d`, `p`, `q`, `dp`, `dq`, `qi` (private). Every member is
    /// optional in the JsonWebKey dictionary, `kty` included: a missing `kty`
    /// is a DataError of the algorithm's import, not a binding TypeError.
    pub const Jwk = struct {
        alg: ?[]const u8 = null,
        d: ?[]const u8 = null,
        dp: ?[]const u8 = null,
        dq: ?[]const u8 = null,
        e: ?[]const u8 = null,
        ext: ?bool = null,
        k: ?[]const u8 = null,
        key_ops: ?[]const []const u8 = null,
        kty: ?[]const u8 = null,
        n: ?[]const u8 = null,
        p: ?[]const u8 = null,
        q: ?[]const u8 = null,
        qi: ?[]const u8 = null,
        use: ?[]const u8 = null,
    };
};

/// Algorithm for `encrypt()` / `decrypt()`. AES-CBC/CTR/GCM and RSA-OAEP share one struct
/// (fields are mode-specific and optional) and dispatch on `name`; a bare string
/// is the fallback form.
pub const Encrypt = union(enum) {
    params: struct {
        additionalData: ?js.TypedArray(u8) = null,
        counter: ?js.TypedArray(u8) = null,
        iv: ?js.TypedArray(u8) = null,
        /// RSA-OAEP.
        label: ?js.TypedArray(u8) = null,
        length: ?u32 = null,
        name: []const u8,
        tagLength: ?u32 = null,
    },
    /// An object without a `name`: a TypeError, as for every algorithm
    /// identifier. Probed before the string, which would coerce it.
    nameless: js.Object,
    name: []const u8,

    /// Null for an object without a name.
    pub fn algoName(self: Encrypt) ?[]const u8 {
        return switch (self) {
            .params => |p| p.name,
            .nameless => null,
            .name => |n| n,
        };
    }
};

/// For `sign()` functionality.
pub const Sign = union(enum) {
    string: []const u8,
    object: struct {
        /// ECDSA. Kept as a value, like `saltLength`: it's only converted
        /// (a HashAlgorithmIdentifier) when the algorithm is ECDSA.
        hash: ?js.Value = null,
        name: []const u8,
        /// RSA-PSS. Kept as a value: it's only converted (an [EnforceRange]
        /// unsigned long) when the algorithm is RSA-PSS, so another algorithm
        /// ignores the member, as normalization does.
        saltLength: ?js.Value = null,
    },
    /// An object without a `name`: a TypeError, as for every algorithm
    /// identifier. Probed after the object, which needs the name.
    nameless: js.Object,

    /// Null for an object without a name.
    pub fn algoName(self: Sign) ?[]const u8 {
        return switch (self) {
            .string => |string| string,
            .object => |object| object.name,
            .nameless => null,
        };
    }

    /// The `hash` member, if present.
    pub fn hash(self: Sign) ?js.Value {
        return switch (self) {
            .string, .nameless => null,
            .object => |object| object.hash,
        };
    }

    /// The `saltLength` member, if present.
    pub fn saltLength(self: Sign) ?js.Value {
        return switch (self) {
            .string, .nameless => null,
            .object => |object| object.saltLength,
        };
    }
};

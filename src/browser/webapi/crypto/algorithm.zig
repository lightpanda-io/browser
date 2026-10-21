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

/// Algorithm for `generateKey()`, normalized as the spec does: its name picks
/// the algorithm (an unknown one is NotSupportedError), then the value is
/// converted to that algorithm's params dictionary (a TypeError without a
/// required member or out of an [EnforceRange] member's range). Taken as a
/// js.Value, not probed by shape, so another algorithm's member (a `hash` on
/// AES, a `namedCurve` on Ed25519) is ignored.
pub const Init = union(enum) {
    /// For RSASSA-PKCS1-v1_5, RSA-PSS, or RSA-OAEP: pass an RsaHashedKeyGenParams object.
    rsa_hashed_key_gen: RsaHashedKeyGen,
    ec_key_gen: EcKeyGen,
    /// For HMAC: pass an HmacKeyGenParams object.
    hmac_key_gen: HmacKeyGen,
    /// For AES variants: pass an AesKeyGenParams object.
    aes_key_gen: AesKeyGen,
    /// An algorithm whose params are just its name (Ed25519, X25519, Ed448,
    /// X448), as the caller spelled it.
    named: []const u8,

    pub fn fromJs(value: js.Value, local: *const js.Local) !Init {
        const name = try identifierName(value, local);
        if (isOneOf(name, &.{ "RSASSA-PKCS1-v1_5", "RSA-PSS", "RSA-OAEP" })) {
            const params = try convert(RsaHashedKeyGen, value, name, local);
            _ = try params.hash.canonical(local);
            return .{ .rsa_hashed_key_gen = params };
        }
        if (isOneOf(name, &.{ "ECDSA", "ECDH" })) {
            return .{ .ec_key_gen = try convert(EcKeyGen, value, name, local) };
        }
        if (isOneOf(name, &.{"HMAC"})) {
            const params = try convert(HmacKeyGen, value, name, local);
            _ = try params.hash.canonical(local);
            return .{ .hmac_key_gen = params };
        }
        if (isOneOf(name, &.{ "AES-CTR", "AES-CBC", "AES-GCM", "AES-KW" })) {
            return .{ .aes_key_gen = try convert(AesKeyGen, value, name, local) };
        }
        if (isOneOf(name, &.{ "Ed25519", "X25519", "Ed448", "X448" })) {
            return .{ .named = name };
        }
        return error.NotSupported;
    }

    /// https://developer.mozilla.org/en-US/docs/Web/API/RsaHashedKeyGenParams
    pub const RsaHashedKeyGen = struct {
        hash: Hash,
        /// This should be at least 2048.
        /// Some organizations are now recommending that it should be 4096.
        modulusLength: js.EnforceRange(u32),
        name: []const u8,
        publicExponent: js.TypedArray(u8),
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/AesKeyGenParams
    pub const AesKeyGen = struct {
        /// An [EnforceRange] unsigned short.
        length: js.EnforceRange(u16),
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
        /// An [EnforceRange] unsigned long, kept as a value for HMAC.lengthParam,
        /// which converts null to 0 as WebIDL does rather than to no length.
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
        const name = try identifierName(value, local);
        if (std.ascii.eqlIgnoreCase(name, "PBKDF2")) {
            const params = try convert(Pbkdf2Params, value, name, local);
            _ = try params.hash.canonical(local);
            return .{ .pbkdf2 = params };
        }
        if (std.ascii.eqlIgnoreCase(name, "HKDF")) {
            const params = try convert(HkdfParams, value, name, local);
            _ = try params.hash.canonical(local);
            return .{ .hkdf = params };
        }
        if (std.ascii.eqlIgnoreCase(name, "ECDH") or std.ascii.eqlIgnoreCase(name, "X25519")) {
            return .{ .ecdh_or_x25519 = try convert(Init.EcdhKeyDeriveParams, value, name, local) };
        }
        return error.NotSupported;
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

/// Algorithm for `importKey()` and unwrapKey's unwrapped key, normalized as
/// Init is: by its name, then that algorithm's params. RSA and HMAC carry a
/// hash, checked here (a TypeError without a name, NotSupportedError if
/// unknown); EC a namedCurve; the others only their name.
pub const Import = union(enum) {
    rsa: struct { hash: Hash, name: []const u8 },
    hmac: struct {
        hash: Hash,
        /// As HmacKeyGen's, converted by HMAC.lengthParam.
        length: ?js.Value = null,
        name: []const u8,
    },
    ec: struct { name: []const u8, namedCurve: []const u8 },
    /// AES, HKDF, PBKDF2, Ed25519, X25519, Ed448, X448.
    named: []const u8,

    pub fn fromJs(value: js.Value, local: *const js.Local) !Import {
        const name = try identifierName(value, local);
        if (isOneOf(name, &.{ "RSASSA-PKCS1-v1_5", "RSA-PSS", "RSA-OAEP" })) {
            const params = try convert(@FieldType(Import, "rsa"), value, name, local);
            _ = try params.hash.canonical(local);
            return .{ .rsa = params };
        }
        if (isOneOf(name, &.{"HMAC"})) {
            const params = try convert(@FieldType(Import, "hmac"), value, name, local);
            _ = try params.hash.canonical(local);
            return .{ .hmac = params };
        }
        if (isOneOf(name, &.{ "ECDSA", "ECDH" })) {
            return .{ .ec = try convert(@FieldType(Import, "ec"), value, name, local) };
        }
        if (isOneOf(name, &.{ "AES-CTR", "AES-CBC", "AES-GCM", "AES-KW", "HKDF", "PBKDF2", "Ed25519", "X25519", "Ed448", "X448" })) {
            return .{ .named = name };
        }
        return error.NotSupported;
    }

    pub fn algoName(self: Import) []const u8 {
        return switch (self) {
            .rsa => |r| r.name,
            .hmac => |h| h.name,
            .ec => |e| e.name,
            .named => |n| n,
        };
    }

    /// The `namedCurve` if this is an EC import, else empty.
    pub fn namedCurve(self: Import) []const u8 {
        return switch (self) {
            .ec => |e| e.namedCurve,
            else => "",
        };
    }

    /// The hash of an RSA or HMAC import, already checked by fromJs.
    pub fn hash(self: Import, local: *const js.Local) !?[]const u8 {
        return switch (self) {
            .rsa => |r| try r.hash.name(local),
            .hmac => |h| try h.hash.name(local),
            else => null,
        };
    }

    /// The unconverted `length` of an HMAC import (HMAC.lengthParam).
    pub fn length(self: Import) ?js.Value {
        return switch (self) {
            .hmac => |h| h.length,
            else => null,
        };
    }
};

/// The name of an AlgorithmIdentifier, `(object or DOMString)`: an object's
/// `name`, required (a TypeError without one), or the value as a string.
/// HashAlgorithmIdentifier has the same conversion.
fn identifierName(value: js.Value, local: *const js.Local) ![]const u8 {
    const identifier = local.jsValueToZig(Hash, value) catch |err| switch (err) {
        error.JsException, error.OutOfMemory => return err,
        else => return local.typeError("algorithm is not an algorithm identifier"),
    };
    return identifier.name(local);
}

/// Whether `name` is one of `names`, ASCII case-insensitively, as algorithm
/// names are matched.
fn isOneOf(name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

/// The error of a failed conversion of a page value: the page's own pending
/// exception, or running out of memory, stays as is; anything else is a
/// TypeError with `message`.
pub fn conversionError(err: anyerror, local: *const js.Local, message: []const u8) anyerror {
    return switch (err) {
        error.JsException, error.OutOfMemory => err,
        else => local.typeError(message),
    };
}

/// `value` as the params dictionary `T` of the algorithm called `name`. The
/// name was read once already, to pick `T`, and isn't read again: a getter on
/// it runs once, as in browsers, so it can't answer another algorithm's name
/// for the params than the one that picked them. Each other member is read in
/// order: absent or undefined takes its default, or null if optional, and is
/// otherwise a TypeError, as is a value that doesn't convert (out of an
/// [EnforceRange] range, say). A string identifier has no members, so it only
/// converts to a dictionary with no required one (as `{name: value}` would).
/// The page's own exception stays pending.
fn convert(comptime T: type, value: js.Value, name: []const u8, local: *const js.Local) !T {
    const object: ?js.Object = if (value.isObject()) value.toObject() else null;
    var out: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field_name, FieldType, attrs| {
        if (comptime std.mem.eql(u8, field_name, "name")) {
            out.name = name;
        } else {
            const member: ?js.Value = blk: {
                const o = object orelse break :blk null;
                if (!o.has(field_name)) break :blk null;
                const m = try o.get(field_name);
                break :blk if (m.isUndefined()) null else m;
            };
            if (member) |m| {
                @field(out, field_name) = local.jsValueToZig(FieldType, m) catch |err| {
                    return conversionError(err, local, "algorithm has a missing or invalid member");
                };
            } else if (comptime attrs.defaultValue(FieldType)) |default| {
                @field(out, field_name) = default;
            } else if (comptime @typeInfo(FieldType) == .optional) {
                @field(out, field_name) = null;
            } else {
                return local.typeError("algorithm has a missing or invalid member");
            }
        }
    }
    return out;
}

/// Key material handed to `importKey()`: either a BufferSource (raw/spki/pkcs8)
/// or a JSON Web Key object (jwk). `bytes` is probed first — a JWK is a plain
/// object and won't coerce to a TypedArray.
pub const KeyData = union(enum) {
    bytes: js.TypedArray(u8),
    jwk: Jwk,

    /// The JWK fields we read on import. Symmetric ("oct") keys only need `kty`
    /// and `k`; `d` marks an asymmetric private key. RSA keys carry `n`/`e`
    /// (public) plus `d`, `p`, `q`, `dp`, `dq`, `qi` (private); EC keys `crv`,
    /// `x`, `y` (public) plus `d` (private). Every member is optional in the
    /// JsonWebKey dictionary, `kty` included: a missing `kty` is a DataError
    /// of the algorithm's import, not a binding TypeError.
    pub const Jwk = struct {
        alg: ?[]const u8 = null,
        crv: ?[]const u8 = null,
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
        x: ?[]const u8 = null,
        y: ?[]const u8 = null,
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

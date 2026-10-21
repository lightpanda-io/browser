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
const Page = @import("../Page.zig");
const common = @import("crypto/common.zig");

const Execution = js.Execution;

/// Represents a cryptographic key obtained from one of the SubtleCrypto methods
/// generateKey(), deriveKey(), importKey(), or unwrapKey().
const CryptoKey = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena = undefined,
/// Algorithm being used.
_type: Type,
/// Whether this is a secret (symmetric), public, or private key. Surfaced as
/// the JS `.type` attribute.
_kind: Kind = .secret,
/// Whether the key is extractable.
_extractable: bool,
/// Bit flags of `usages`; see `Usages` type.
_usages: u8,
/// Raw bytes of key.
_key: []const u8,
/// Metadata needed to reconstruct the JS `.algorithm` dictionary. `hash` is
/// duped into the key's arena by init; `name`/`named_curve` are static.
_algorithm: Algorithm,
/// Different algorithms may use different data structures;
/// this union can be used for such situations. Active field is understood
/// from `_type`.
_vary: union(enum) {
    none,
    /// Used by HMAC.
    digest: *const crypto.EVP_MD,
    /// Used by asymmetric algorithms (X25519, Ed25519).
    pkey: *crypto.EVP_PKEY,
} = .none,

/// Captures the algorithm parameters reported back via the `.algorithm`
/// accessor. `hash` is only set for HMAC (and other hashed algorithms).
pub const Algorithm = struct {
    name: []const u8,
    hash: ?[]const u8 = null,
    named_curve: ?[]const u8 = null,
    modulus_length: ?u32 = null,
    /// HMAC: the key's length in bits, which needn't fill its last byte.
    length: ?u32 = null,
    /// RSA: big-endian, duped into the key's arena by init.
    public_exponent: ?[]const u8 = null,
};

/// https://developer.mozilla.org/en-US/docs/Web/API/CryptoKeyPair
pub const Pair = struct {
    privateKey: *CryptoKey,
    publicKey: *CryptoKey,
};

/// Key-creating functions expect this format.
pub const KeyOrPair = union(enum) { key: *CryptoKey, pair: Pair };

pub const Type = enum(u8) { hmac, rsa, x25519, aes, derive, ec, ed25519 };

pub const Kind = enum {
    secret,
    public,
    private,

    pub fn toString(self: Kind) []const u8 {
        return @tagName(self);
    }
};

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

/// Copies `key` into an owned pooled arena, duping the caller-provided
/// slices (`_key`, `_algorithm.hash`, `_algorithm.public_exponent`). `_algorithm.name` and `_named_curve`
/// are expected to be static strings. Takes ownership of `_vary.pkey`.
pub fn init(exec: *const Execution, key: CryptoKey) !*CryptoKey {
    const arena = try exec.getArena(.tiny, "CryptoKey");
    errdefer arena.release();

    const self = try arena.create(CryptoKey);
    self.* = key;
    self._arena = arena;
    self._key = try arena.dupe(u8, key._key);
    if (key._algorithm.hash) |hash| {
        self._algorithm.hash = try arena.dupe(u8, hash);
    }
    if (key._algorithm.public_exponent) |exponent| {
        self._algorithm.public_exponent = try arena.dupe(u8, exponent);
    }
    return self;
}

pub fn deinit(self: *CryptoKey, _: *Page) void {
    switch (self._vary) {
        .pkey => |pkey| crypto.EVP_PKEY_free(pkey),
        .none, .digest => {},
    }
    self._arena.release();
}

/// A CryptoKey is serializable (structuredClone, postMessage, IndexedDB):
/// its internal slots are written out, and its material as bytes: a secret
/// key's, or an EVP_PKEY's SPKI (public) or PKCS#8 (private) DER. An HMAC
/// key's digest is found again from its hash.
pub fn structuredSerialize(self: *const CryptoKey, writer: *js.StructuredWriter) !void {
    writer.writeUint32(@backingInt(self._type));
    writer.writeUint32(@backingInt(self._kind));
    writer.writeUint32(@intFromBool(self._extractable));
    writer.writeUint32(self._usages);
    writer.writeBytes(self._key);

    const algorithm = self._algorithm;
    writer.writeBytes(algorithm.name);
    writeOptional(writer, algorithm.hash);
    writeOptional(writer, algorithm.named_curve);
    writeOptional(writer, algorithm.modulus_length);
    writeOptional(writer, algorithm.length);
    writeOptional(writer, algorithm.public_exponent);

    switch (self._vary) {
        .pkey => |pkey| {
            const der = common.pkeyDer(pkey, self._kind == .public, writer.local.call_arena) catch return error.DataClone;
            writer.writeBytes(der);
        },
        .none, .digest => writer.writeBytes(""),
    }
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*CryptoKey {
    const key_type = std.enums.fromInt(Type, try reader.readUint32()) orelse return error.DataClone;
    const kind = std.enums.fromInt(Kind, try reader.readUint32()) orelse return error.DataClone;
    const extractable = try reader.readUint32() != 0;
    const usages: u8 = std.math.cast(u8, try reader.readUint32()) orelse return error.DataClone;

    const arena = try page.getArena(.tiny, "CryptoKey");
    errdefer arena.release();

    const key = try arena.dupe(u8, try reader.readBytes());
    var algorithm: Algorithm = .{ .name = try arena.dupe(u8, try reader.readBytes()) };
    algorithm.hash = try readOptionalBytes(reader, arena);
    algorithm.named_curve = try readOptionalBytes(reader, arena);
    algorithm.modulus_length = try readOptionalUint32(reader);
    algorithm.length = try readOptionalUint32(reader);
    algorithm.public_exponent = try readOptionalBytes(reader, arena);

    const der = try reader.readBytes();
    const vary: @FieldType(CryptoKey, "_vary") = switch (key_type) {
        .rsa, .ec, .ed25519, .x25519 => .{
            .pkey = common.parseDer(if (kind == .public) "spki" else "pkcs8", der) catch return error.DataClone,
        },
        .hmac => .{
            .digest = crypto.findDigest(algorithm.hash orelse return error.DataClone) catch return error.DataClone,
        },
        .aes, .derive => .none,
    };
    errdefer switch (vary) {
        .pkey => |pkey| crypto.EVP_PKEY_free(pkey),
        .none, .digest => {},
    };

    const self = try arena.create(CryptoKey);
    self.* = .{
        ._arena = arena,
        ._type = key_type,
        ._kind = kind,
        ._extractable = extractable,
        ._usages = usages,
        ._key = key,
        ._algorithm = algorithm,
        ._vary = vary,
    };
    return self;
}

/// An optional member: a flag, then the value if there's one.
fn writeOptional(writer: *js.StructuredWriter, value: anytype) void {
    const v = value orelse {
        writer.writeUint32(0);
        return;
    };
    writer.writeUint32(1);
    if (@TypeOf(v) == u32) {
        writer.writeUint32(v);
    } else {
        writer.writeBytes(v);
    }
}

fn readOptionalBytes(reader: *js.StructuredReader, arena: *lp.Arena) !?[]const u8 {
    if (try reader.readUint32() == 0) {
        return null;
    }
    return try arena.dupe(u8, try reader.readBytes());
}

fn readOptionalUint32(reader: *js.StructuredReader) !?u32 {
    if (try reader.readUint32() == 0) {
        return null;
    }
    return try reader.readUint32();
}

pub fn releaseRef(self: *CryptoKey, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *CryptoKey) void {
    self._rc.acquire();
}

pub fn canDeriveBits(self: *const CryptoKey) bool {
    return self._usages & Usages.deriveBits != 0;
}

pub fn canDeriveKey(self: *const CryptoKey) bool {
    return self._usages & Usages.deriveKey != 0;
}

pub fn canExportKey(self: *const CryptoKey) bool {
    return self._extractable;
}

/// Only valid for HMAC.
pub fn getDigest(self: *const CryptoKey) *const crypto.EVP_MD {
    return self._vary.digest;
}

/// Only valid for asymmetric algorithms (X25519, Ed25519).
pub fn getKeyObject(self: *const CryptoKey) *crypto.EVP_PKEY {
    return self._vary.pkey;
}

pub fn getType(self: *const CryptoKey) Kind {
    return self._kind;
}

pub fn getExtractable(self: *const CryptoKey) bool {
    return self._extractable;
}

/// The shape of the `.algorithm` dictionary depends on the algorithm. AES and
/// HMAC expose a `length` in bits (AES's from the key material, HMAC's as
/// stored, since it needn't fill the last byte); HMAC also exposes a nested
/// `hash`.
const AlgorithmReport = union(enum) {
    keyed: struct { name: []const u8, length: u32 },
    hmac: struct { name: []const u8, length: u32, hash: struct { name: []const u8 } },
    ec: struct { name: []const u8, namedCurve: []const u8 },
    rsa: struct {
        name: []const u8,
        hash: struct { name: []const u8 },
        modulusLength: u32,
        publicExponent: js.TypedArray(u8),
    },
    named: struct { name: []const u8 },
};

pub fn getAlgorithm(self: *const CryptoKey) AlgorithmReport {
    return switch (self._type) {
        // AES keys are 16, 24 or 32 bytes.
        .aes => .{ .keyed = .{ .name = self._algorithm.name, .length = @intCast(self._key.len * 8) } },
        .hmac => .{ .hmac = .{
            .name = self._algorithm.name,
            .length = self._algorithm.length orelse 0,
            .hash = .{ .name = self._algorithm.hash orelse "" },
        } },
        .ec => .{ .ec = .{
            .name = self._algorithm.name,
            .namedCurve = self._algorithm.named_curve orelse "",
        } },
        .rsa => .{ .rsa = .{
            .name = self._algorithm.name,
            .hash = .{ .name = self._algorithm.hash orelse "" },
            .modulusLength = self._algorithm.modulus_length orelse 0,
            .publicExponent = .{ .values = self._algorithm.public_exponent orelse "" },
        } },
        else => .{ .named = .{ .name = self._algorithm.name } },
    };
}

/// Returns the active usages, de-duplicated, in a stable order.
pub fn getUsages(self: *const CryptoKey, exec: *const Execution) ![]const []const u8 {
    // zig fmt: off
    const all = [_]struct { mask: u8, name: []const u8 }{
        .{ .mask = Usages.encrypt,    .name = "encrypt" },
        .{ .mask = Usages.decrypt,    .name = "decrypt" },
        .{ .mask = Usages.sign,       .name = "sign" },
        .{ .mask = Usages.verify,     .name = "verify" },
        .{ .mask = Usages.deriveKey,  .name = "deriveKey" },
        .{ .mask = Usages.deriveBits, .name = "deriveBits" },
        .{ .mask = Usages.wrapKey,    .name = "wrapKey" },
        .{ .mask = Usages.unwrapKey,  .name = "unwrapKey" },
    };
    // zig fmt: on

    var buf: [all.len][]const u8 = undefined;
    var n: usize = 0;
    for (all) |entry| {
        if (self._usages & entry.mask != 0) {
            buf[n] = entry.name;
            n += 1;
        }
    }
    return exec.local_arena.dupe([]const u8, buf[0..n]);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CryptoKey);

    pub const Meta = struct {
        pub const name = "CryptoKey";

        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(CryptoKey.getType, null, .{});
    pub const extractable = bridge.accessor(CryptoKey.getExtractable, null, .{});
    // Each returns its cached object: the same one on every read, as the
    // spec's [[algorithm_cached]] and [[usages_cached]] slots are.
    pub const algorithm = bridge.accessor(CryptoKey.getAlgorithm, null, .{ .cache = .{ .private = "crypto_key_algorithm" } });
    pub const usages = bridge.accessor(CryptoKey.getUsages, null, .{ .cache = .{ .private = "crypto_key_usages" } });
};

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

const crypto = @import("../../sys/libcrypto.zig");

const js = @import("../js/js.zig");

const Execution = js.Execution;

/// Represents a cryptographic key obtained from one of the SubtleCrypto methods
/// generateKey(), deriveKey(), importKey(), or unwrapKey().
const CryptoKey = @This();

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
/// Metadata needed to reconstruct the JS `.algorithm` dictionary. The strings
/// are expected to outlive the key (arena-allocated alongside it).
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
};

/// https://developer.mozilla.org/en-US/docs/Web/API/CryptoKeyPair
pub const Pair = struct {
    privateKey: *CryptoKey,
    publicKey: *CryptoKey,
};

/// Key-creating functions expect this format.
pub const KeyOrPair = union(enum) { key: *CryptoKey, pair: Pair };

pub const Type = enum(u8) { hmac, rsa, x25519, aes, derive, ec };

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

pub fn canEncrypt(self: *const CryptoKey) bool {
    return self._usages & Usages.encrypt != 0;
}

pub fn canDecrypt(self: *const CryptoKey) bool {
    return self._usages & Usages.decrypt != 0;
}

pub fn canSign(self: *const CryptoKey) bool {
    return self._usages & Usages.sign != 0;
}

pub fn canVerify(self: *const CryptoKey) bool {
    return self._usages & Usages.verify != 0;
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
/// HMAC expose a `length` (in bits, derived from the key material); HMAC also
/// exposes a nested `hash`.
const AlgorithmReport = union(enum) {
    keyed: struct { name: []const u8, length: u32 },
    hmac: struct { name: []const u8, length: u32, hash: struct { name: []const u8 } },
    ec: struct { name: []const u8, namedCurve: []const u8 },
    named: struct { name: []const u8 },
};

pub fn getAlgorithm(self: *const CryptoKey) AlgorithmReport {
    const length: u32 = @intCast(self._key.len * 8);
    return switch (self._type) {
        .aes => .{ .keyed = .{ .name = self._algorithm.name, .length = length } },
        .hmac => .{ .hmac = .{
            .name = self._algorithm.name,
            .length = length,
            .hash = .{ .name = self._algorithm.hash orelse "" },
        } },
        .ec => .{ .ec = .{
            .name = self._algorithm.name,
            .namedCurve = self._algorithm.named_curve orelse "",
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
    return exec.call_arena.dupe([]const u8, buf[0..n]);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CryptoKey);

    pub const Meta = struct {
        pub const name = "CryptoKey";

        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const @"type" = bridge.accessor(CryptoKey.getType, null, .{});
    pub const extractable = bridge.accessor(CryptoKey.getExtractable, null, .{});
    pub const algorithm = bridge.accessor(CryptoKey.getAlgorithm, null, .{});
    pub const usages = bridge.accessor(CryptoKey.getUsages, null, .{});
};

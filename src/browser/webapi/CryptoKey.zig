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

const crypto = @import("../../sys/libcrypto.zig");

const js = @import("../js/js.zig");

/// Represents a cryptographic key obtained from one of the SubtleCrypto methods
/// generateKey(), deriveKey(), importKey(), or unwrapKey().
const CryptoKey = @This();

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

/// https://developer.mozilla.org/en-US/docs/Web/API/CryptoKeyPair
pub const Pair = struct {
    privateKey: *CryptoKey,
    publicKey: *CryptoKey,
};

/// Key-creating functions expect this format.
pub const KeyOrPair = union(enum) { key: *CryptoKey, pair: Pair };

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

pub inline fn canSign(self: *const CryptoKey) bool {
    return self._usages & Usages.sign != 0;
}

pub inline fn canVerify(self: *const CryptoKey) bool {
    return self._usages & Usages.verify != 0;
}

pub inline fn canDeriveBits(self: *const CryptoKey) bool {
    return self._usages & Usages.deriveBits != 0;
}

pub inline fn canExportKey(self: *const CryptoKey) bool {
    return self._extractable;
}

/// Only valid for HMAC.
pub inline fn getDigest(self: *const CryptoKey) *const crypto.EVP_MD {
    return self._vary.digest;
}

/// Only valid for asymmetric algorithms (X25519, Ed25519).
pub inline fn getKeyObject(self: *const CryptoKey) *crypto.EVP_PKEY {
    return self._vary.pkey;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CryptoKey);

    pub const Meta = struct {
        pub const name = "CryptoKey";

        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };
};

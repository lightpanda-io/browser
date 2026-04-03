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
    /// Can be Ed25519 or X25519.
    name: []const u8,
    /// Can be Ed25519 or X25519.
    object: struct { name: []const u8 },

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

/// Algorithm for deriveBits() and deriveKey().
pub const Derive = union(enum) {
    ecdh_or_x25519: Init.EcdhKeyDeriveParams,
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

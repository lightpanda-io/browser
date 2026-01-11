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

/// NOTE: I think we can use extern union and cast this to intended algorithm
/// by `name` field. Not sure if it'd make difference memory/performance wise.
const Algorithm = union(enum) {
    rsa_hashed_key_gen: RSA,
    hmac_key_gen: HMAC,

    /// https://developer.mozilla.org/en-US/docs/Web/API/RsaHashedKeyGenParams
    const RSA = struct {
        name: []const u8,
        /// This should be at least 2048.
        /// Some organizations are now recommending that it should be 4096.
        modulusLength: u32,
        publicExponent: js.TypedArray(u8),
        hash: []const u8,
    };

    /// https://developer.mozilla.org/en-US/docs/Web/API/HmacKeyGenParams
    const HMAC = struct {
        name: []const u8,
        /// Its also possible to pass this in an object.
        hash: union(enum) {
            str: []const u8,
            obj: struct { name: []const u8 },
        },
        /// If omitted, default is the block size of the chosen hash function.
        length: ?usize,
    };
};

/// Returns the desired digest by its name.
fn getDigest(name: []const u8) error{Invalid}!*const crypto.EVP_MD {
    const digest = std.meta.stringToEnum(enum {
        @"SHA-1",
        @"SHA-256",
        @"SHA-384",
        @"SHA-512",
    }, name) orelse return error.Invalid;

    return switch (digest) {
        .@"SHA-1" => crypto.EVP_sha1(),
        .@"SHA-256" => crypto.EVP_sha256(),
        .@"SHA-384" => crypto.EVP_sha384(),
        .@"SHA-512" => crypto.EVP_sha512(),
    };
}

pub const CryptoKey = struct {
    _algorithm: Algorithm,
    /// Whether the key is extractable.
    _extractable: bool,
    /// Bit flags of `usages`.
    _usages: u8,
    /// Algorithm specific data.
    _internal: union {
        hmac: []u8,
    },

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
    ) !*CryptoKey {
        // TODO.
        _ = key_usages;
        return switch (algorithm) {
            .hmac_key_gen => |hmac| try initHMAC(hmac, extractable, page),
            else => @panic("NYI"),
        };
    }

    fn initHMAC(algorithm: Algorithm.HMAC, extractable: bool, page: *Page) !*CryptoKey {
        const hash = switch (algorithm.hash) {
            .str => |str| str,
            .obj => |obj| obj.name,
        };
        // Find digest.
        const digest = try getDigest(hash);

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

        return page._factory.create(CryptoKey{
            ._algorithm = .{
                .hmac_key_gen = .{
                    .name = "HMAC",
                    .hash = .{ .obj = .{ .name = hash } },
                    .length = block_size,
                },
            },
            ._extractable = extractable,
            ._usages = 0,
            ._internal = .{ .hmac = key },
        });
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

/// Generate a new key (for symmetric algorithms) or key pair (for public-key algorithms).
pub fn generateKey(
    _: *const SubtleCrypto,
    algorithm: Algorithm,
    extractable: bool,
    key_usages: []const []const u8,
    page: *Page,
) !*CryptoKey {
    return CryptoKey.init(algorithm, extractable, key_usages, page);
}

/// Generate a digital signature.
pub fn sign(
    _: *const SubtleCrypto,
    algorithm: []const u8,
    key: *const CryptoKey,
    data: []const u8,
) void {
    _ = algorithm;
    _ = key;
    _ = data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SubtleCrypto);

    pub const Meta = struct {
        pub const name = "SubtleCrypto";

        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const generateKey = bridge.function(SubtleCrypto.generateKey, .{});
    pub const sign = bridge.function(SubtleCrypto.sign, .{});
};

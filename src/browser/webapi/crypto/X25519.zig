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

//! Interprets `CryptoKey` for X25519.

const std = @import("std");
const lp = @import("lightpanda");
const crypto = @import("../../../sys/libcrypto.zig");

const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const CryptoKey = @import("../CryptoKey.zig");

pub fn init(
    extractable: bool,
    key_usages: []const []const u8,
    page: *Page,
) !js.Promise {
    // This code has too many allocations here and there, might be nice to
    // gather them together with a single alloc call. Not sure if factory
    // pattern is suitable for it though.

    const local = page.js.local.?;

    // Calculate usages; only matters for private key.
    // Only deriveKey() and deriveBits() be used for X25519.
    if (key_usages.len == 0) {
        return local.rejectPromise(.{
            .dom_exception = .{ .err = error.SyntaxError },
        });
    }
    var mask: u8 = 0;
    iter_usages: for (key_usages) |usage| {
        inline for ([_][]const u8{ "deriveKey", "deriveBits" }) |name| {
            if (std.mem.eql(u8, name, usage)) {
                mask |= @field(CryptoKey.Usages, name);
                continue :iter_usages;
            }
        }
        // Unknown usage if got here.
        return local.rejectPromise(.{
            .dom_exception = .{ .err = error.SyntaxError },
        });
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
    ) orelse return error.OutOfMemory;

    // Create EVP_PKEY for private key.
    // Seems we can use `EVP_PKEY_from_raw_private_key` for this, Chrome
    // prefer not to, yet BoringSSL added it and recommends instead of what
    // we're doing currently.
    const private_pkey = crypto.EVP_PKEY_new_raw_private_key(
        crypto.EVP_PKEY_X25519,
        null,
        private_key.ptr,
        private_key.len,
    ) orelse return error.OutOfMemory;

    const private = try page._factory.create(CryptoKey{
        ._type = .x25519,
        ._extractable = extractable,
        ._usages = mask,
        ._key = private_key,
        ._vary = .{ .pkey = private_pkey },
    });
    errdefer page._factory.destroy(private);

    const public = try page._factory.create(CryptoKey{
        ._type = .x25519,
        // Public keys are always extractable.
        ._extractable = true,
        // Always empty for public key.
        ._usages = 0,
        ._key = public_value,
        ._vary = .{ .pkey = public_pkey },
    });

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

pub fn deriveBits(
    private: *const CryptoKey,
    public: *const CryptoKey,
    length_in_bits: usize,
    page: *Page,
) !js.ArrayBuffer {
    if (!private.canDeriveBits()) {
        return error.InvalidAccessError;
    }

    const ctx = crypto.EVP_PKEY_CTX_new(private.getKeyObject(), null) orelse {
        // Failed on our end.
        return error.Internal;
    };
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
    lp.assert(derived_key.len == out_key_len, "X25519.deriveBits", .{});

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

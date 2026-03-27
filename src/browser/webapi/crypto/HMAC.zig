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

//! Interprets `CryptoKey` for HMAC.

const std = @import("std");
const lp = @import("lightpanda");
const crypto = @import("../../../sys/libcrypto.zig");

const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");
const algorithm = @import("algorithm.zig");

const CryptoKey = @import("../CryptoKey.zig");

pub fn init(
    params: algorithm.Init.HmacKeyGen,
    extractable: bool,
    key_usages: []const []const u8,
    page: *Page,
) !js.Promise {
    const local = page.js.local.?;
    // Find digest.
    const digest = crypto.findDigest(switch (params.hash) {
        .string => |str| str,
        .object => |obj| obj.name,
    }) catch return local.rejectPromise(.{
        .dom_exception = .{ .err = error.SyntaxError },
    });

    // Calculate usages mask.
    if (key_usages.len == 0) {
        return local.rejectPromise(.{
            .dom_exception = .{ .err = error.SyntaxError },
        });
    }
    const decls = @typeInfo(CryptoKey.Usages).@"struct".decls;
    var mask: u8 = 0;
    iter_usages: for (key_usages) |usage| {
        inline for (decls) |decl| {
            if (std.mem.eql(u8, decl.name, usage)) {
                mask |= @field(CryptoKey.Usages, decl.name);
                continue :iter_usages;
            }
        }
        // Unknown usage if got here.
        return local.rejectPromise(.{
            .dom_exception = .{ .err = error.SyntaxError },
        });
    }

    const block_size: usize = blk: {
        // Caller provides this in bits, not bytes.
        if (params.length) |length| {
            break :blk length >> 3;
        }
        // Prefer block size of the hash function instead.
        break :blk crypto.EVP_MD_block_size(digest);
    };

    // Should we reject this in promise too?
    const key = try page.arena.alloc(u8, block_size);
    errdefer page.arena.free(key);

    // HMAC is simply CSPRNG.
    const res = crypto.RAND_bytes(key.ptr, key.len);
    lp.assert(res == 1, "HMAC.init", .{ .res = res });

    const crypto_key = try page._factory.create(CryptoKey{
        ._type = .hmac,
        ._extractable = extractable,
        ._usages = mask,
        ._key = key,
        ._vary = .{ .digest = digest },
    });

    return local.resolvePromise(crypto_key);
}

pub fn sign(
    algo: algorithm.Sign,
    crypto_key: *const CryptoKey,
    data: []const u8,
    page: *Page,
) !js.Promise {
    var resolver = page.js.local.?.createPromiseResolver();

    if (!algo.isHMAC() or !crypto_key.canSign()) {
        resolver.rejectError("HMAC.sign", .{ .dom_exception = .{ .err = error.InvalidAccessError } });
        return resolver.promise();
    }

    const buffer = try page.call_arena.alloc(u8, crypto.EVP_MD_size(crypto_key.getDigest()));
    var out_len: u32 = 0;
    // Try to sign.
    _ = crypto.HMAC(
        crypto_key.getDigest(),
        @ptrCast(crypto_key._key.ptr),
        crypto_key._key.len,
        data.ptr,
        data.len,
        buffer.ptr,
        &out_len,
    ) orelse {
        page.call_arena.free(buffer);
        // Failure.
        resolver.rejectError("HMAC.sign", .{ .dom_exception = .{ .err = error.InvalidAccessError } });
        return resolver.promise();
    };

    // Success.
    resolver.resolve("HMAC.sign", js.ArrayBuffer{ .values = buffer[0..out_len] });
    return resolver.promise();
}

pub fn verify(
    crypto_key: *const CryptoKey,
    signature: []const u8,
    data: []const u8,
    page: *Page,
) !js.Promise {
    var resolver = page.js.local.?.createPromiseResolver();

    if (!crypto_key.canVerify()) {
        resolver.rejectError("HMAC.verify", .{ .dom_exception = .{ .err = error.InvalidAccessError } });
        return resolver.promise();
    }

    var buffer: [crypto.EVP_MAX_MD_BLOCK_SIZE]u8 = undefined;
    var out_len: u32 = 0;
    // Try to sign.
    const signed = crypto.HMAC(
        crypto_key.getDigest(),
        @ptrCast(crypto_key._key.ptr),
        crypto_key._key.len,
        data.ptr,
        data.len,
        &buffer,
        &out_len,
    ) orelse {
        resolver.resolve("HMAC.verify", false);
        return resolver.promise();
    };

    // CRYPTO_memcmp compare in constant time so prohibits time-based attacks.
    const res = crypto.CRYPTO_memcmp(signed, @ptrCast(signature.ptr), signature.len);
    resolver.resolve("HMAC.verify", res == 0);
    return resolver.promise();
}

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

//! Key-derivation functions for `deriveBits()`: PBKDF2 and HKDF. Both operate
//! on a raw "secret" base key (imported via the `raw` format).

const std = @import("std");

const js = @import("../../js/js.zig");
const CryptoKey = @import("../CryptoKey.zig");
const crypto = @import("../../../sys/libcrypto.zig");

const algorithm = @import("algorithm.zig");

const Execution = js.Execution;

/// Errors a derivation can raise, each mapping to a specific DOMException name.
pub const Error = error{ InvalidAccessError, NotSupported, OperationError, OutOfMemory };

/// Validates the base key against the requested algorithm (shared by PBKDF2 and
/// HKDF). `usage_ok` is the caller-checked usage gate (deriveBits for
/// `deriveBits()`, deriveKey for `deriveKey()`); the key must also have been
/// created for this same algorithm. Either mismatch is an InvalidAccessError.
fn checkBaseKey(base_key: *const CryptoKey, name: []const u8, usage_ok: bool) Error!void {
    if (!usage_ok) {
        return error.InvalidAccessError;
    }
    if (!std.ascii.eqlIgnoreCase(base_key._algorithm.name, name)) {
        return error.InvalidAccessError;
    }
}

/// `length` is the requested output size in bits: null and non-multiples of 8
/// are OperationErrors. Returns the output byte length.
fn outputLen(length: ?u32) Error!usize {
    const bits = length orelse return error.OperationError;
    if (bits % 8 != 0) {
        return error.OperationError;
    }
    return bits / 8;
}

pub fn pbkdf2(
    base_key: *const CryptoKey,
    params: algorithm.Derive.Pbkdf2Params,
    length: ?u32,
    usage_ok: bool,
    exec: *const Execution,
) Error![]const u8 {
    try checkBaseKey(base_key, "PBKDF2", usage_ok);
    const digest = crypto.findDigest(params.hash.name()) catch return error.NotSupported;
    const out = try exec.call_arena.alloc(u8, try outputLen(length));
    // A zero-length derivation is valid and yields an empty buffer; the C
    // routines reject a zero output length, so short-circuit here.
    if (out.len == 0) {
        return out;
    }

    const salt = params.salt.values;
    const res = crypto.PKCS5_PBKDF2_HMAC(
        @ptrCast(base_key._key.ptr),
        base_key._key.len,
        @ptrCast(salt.ptr),
        salt.len,
        params.iterations,
        digest,
        out.len,
        out.ptr,
    );
    if (res != 1) {
        return error.OperationError;
    }
    return out;
}

pub fn hkdf(
    base_key: *const CryptoKey,
    params: algorithm.Derive.HkdfParams,
    length: ?u32,
    usage_ok: bool,
    exec: *const Execution,
) Error![]const u8 {
    try checkBaseKey(base_key, "HKDF", usage_ok);
    const digest = crypto.findDigest(params.hash.name()) catch return error.NotSupported;
    const out = try exec.call_arena.alloc(u8, try outputLen(length));
    // A zero-length derivation is valid and yields an empty buffer; the C
    // routines reject a zero output length, so short-circuit here.
    if (out.len == 0) {
        return out;
    }

    const salt = params.salt.values;
    const info = params.info.values;
    const res = crypto.HKDF(
        out.ptr,
        out.len,
        digest,
        @ptrCast(base_key._key.ptr),
        base_key._key.len,
        @ptrCast(salt.ptr),
        salt.len,
        @ptrCast(info.ptr),
        info.len,
    );
    if (res != 1) {
        return error.OperationError;
    }
    return out;
}

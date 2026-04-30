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

//! RSA generateKey parameter validation. See AES.zig for the rationale.

const std = @import("std");

const algorithm = @import("algorithm.zig");

pub fn validate(params: algorithm.Init.RsaHashedKeyGen, key_usages: []const []const u8) !void {
    const allowed: []const []const u8 = blk: {
        if (eql(params.name, "RSASSA-PKCS1-v1_5") or eql(params.name, "RSA-PSS")) {
            break :blk &.{ "sign", "verify" };
        }
        if (eql(params.name, "RSA-OAEP")) {
            break :blk &.{ "encrypt", "decrypt", "wrapKey", "unwrapKey" };
        }
        return error.NotSupported;
    };

    const hash_name = switch (params.hash) {
        .string => |s| s,
        .object => |o| o.name,
    };
    if (!eql(hash_name, "SHA-1") and
        !eql(hash_name, "SHA-256") and
        !eql(hash_name, "SHA-384") and
        !eql(hash_name, "SHA-512"))
    {
        return error.NotSupported;
    }

    for (key_usages) |usage| {
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, usage)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            return error.SyntaxError;
        }
    }

    if (!isValidPublicExponent(params.publicExponent.values)) {
        return error.OperationError;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

// WebCrypto only mandates rejection on key-generation failure, but in
// practice browsers accept the standard exponents 3 and 65537 and reject
// the rest. Match that.
fn isValidPublicExponent(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = 0;
    while (i + 1 < bytes.len and bytes[i] == 0) : (i += 1) {}
    const trimmed = bytes[i..];
    if (trimmed.len == 1 and trimmed[0] == 3) return true;
    if (trimmed.len == 3 and trimmed[0] == 0x01 and trimmed[1] == 0x00 and trimmed[2] == 0x01) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

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

//! AES generateKey parameter validation.
//!
//! Key generation itself is not implemented; this module rejects malformed
//! input with the spec-mandated error name so the failure-path WPT tests
//! match. Successful inputs fall through to the caller's `not_implemented`
//! warning + `NotSupportedError`.

const std = @import("std");

const algorithm = @import("algorithm.zig");

/// Per WebCrypto: "Generate Key" operation for AES-CBC/CTR/GCM/KW.
/// Validation order matches the spec: usages → length → empty usages.
pub fn validate(params: algorithm.Init.AesKeyGen, key_usages: []const []const u8) !void {
    const allowed: []const []const u8 = blk: {
        if (eql(params.name, "AES-CBC") or
            eql(params.name, "AES-CTR") or
            eql(params.name, "AES-GCM"))
        {
            break :blk &.{ "encrypt", "decrypt", "wrapKey", "unwrapKey" };
        }
        if (eql(params.name, "AES-KW")) {
            break :blk &.{ "wrapKey", "unwrapKey" };
        }
        return error.NotSupported;
    };

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

    if (params.length != 128 and params.length != 192 and params.length != 256) {
        return error.OperationError;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

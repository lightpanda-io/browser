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

//! ECDSA / ECDH generateKey parameter validation. See AES.zig for
//! the rationale on validate-without-generate.

const std = @import("std");

const algorithm = @import("algorithm.zig");

pub fn validate(params: algorithm.Init.EcKeyGen, key_usages: []const []const u8) !void {
    const allowed: []const []const u8 = blk: {
        if (eql(params.name, "ECDSA")) {
            break :blk &.{ "sign", "verify" };
        }
        if (eql(params.name, "ECDH")) {
            break :blk &.{ "deriveKey", "deriveBits" };
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

    // Per spec, an unsupported `namedCurve` is NotSupportedError, not OperationError —
    // unlike AES length, where the algorithm registers the value as invalid.
    if (!eql(params.namedCurve, "P-256") and
        !eql(params.namedCurve, "P-384") and
        !eql(params.namedCurve, "P-521"))
    {
        return error.NotSupported;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

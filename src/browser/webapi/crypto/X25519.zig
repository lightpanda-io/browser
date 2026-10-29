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

//! X25519's deriveBits. Its keys are generated, imported and exported in
//! OKP.zig.

const crypto = @import("../../../sys/libcrypto.zig");

const js = @import("../../js/js.zig");

const CryptoKey = @import("../CryptoKey.zig");
const common = @import("common.zig");

const Execution = js.Execution;

/// X25519 key agreement (RFC 7748): the shared secret of `private` and the
/// peer `public`, cut to `length_in_bits` (all 256 bits when null). The peer
/// must be an X25519 public key, else InvalidAccessError. An all-zero secret
/// (a peer of small order, which libcrypto refuses) or a length beyond the
/// secret is OperationError.
pub fn deriveBits(
    private: *const CryptoKey,
    public: *const CryptoKey,
    length_in_bits: ?u32,
    exec: *const Execution,
) error{ InvalidAccessError, OperationError, OutOfMemory }![]const u8 {
    if (public._type != .x25519 or public._kind != .public) {
        return error.InvalidAccessError;
    }

    const ctx = crypto.EVP_PKEY_CTX_new(private.getKeyObject(), null) orelse return error.OutOfMemory;
    defer crypto.EVP_PKEY_CTX_free(ctx);
    if (crypto.EVP_PKEY_derive_init(ctx) != 1 or crypto.EVP_PKEY_derive_set_peer(ctx, public.getKeyObject()) != 1) {
        crypto.ERR_clear_error();
        return error.OperationError;
    }

    const secret = try exec.local_arena.alloc(u8, 32);
    var secret_len: usize = secret.len;
    if (crypto.EVP_PKEY_derive(ctx, secret.ptr, &secret_len) != 1 or secret_len != secret.len) {
        crypto.ERR_clear_error();
        return error.OperationError;
    }
    return common.leadingBits(secret, length_in_bits);
}

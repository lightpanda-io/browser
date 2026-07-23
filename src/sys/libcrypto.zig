// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! libcrypto utilities we use throughout browser.

const std = @import("std");

pub const struct_env_md_st = opaque {};
pub const EVP_MD = struct_env_md_st;
pub const struct_engine_st = opaque {};
pub const ENGINE = struct_engine_st;
pub const struct_ec_key_st = opaque {};
pub const EC_KEY = struct_ec_key_st;
pub const struct_evp_pkey_st = opaque {};
pub const EVP_PKEY = struct_evp_pkey_st;
pub const struct_evp_pkey_ctx_st = opaque {};
pub const EVP_PKEY_CTX = struct_evp_pkey_ctx_st;

pub extern fn RAND_bytes(buf: [*]u8, len: usize) c_int;

pub extern fn EVP_sha1() *const EVP_MD;
pub extern fn EVP_sha256() *const EVP_MD;
pub extern fn EVP_sha384() *const EVP_MD;
pub extern fn EVP_sha512() *const EVP_MD;

pub const EVP_MAX_MD_SIZE = 64;
pub const EVP_MAX_MD_BLOCK_SIZE = 128;

pub extern fn EVP_MD_size(md: ?*const EVP_MD) usize;
pub extern fn EVP_MD_block_size(md: ?*const EVP_MD) usize;

pub extern fn CRYPTO_memcmp(a: ?*const anyopaque, b: ?*const anyopaque, len: usize) c_int;

pub extern fn HMAC(
    evp_md: *const EVP_MD,
    key: *const anyopaque,
    key_len: usize,
    data: [*]const u8,
    data_len: usize,
    out: [*]u8,
    out_len: *c_uint,
) ?[*]u8;

pub extern fn PKCS5_PBKDF2_HMAC(
    password: [*c]const u8,
    password_len: usize,
    salt: [*c]const u8,
    salt_len: usize,
    iterations: c_uint,
    digest: *const EVP_MD,
    key_len: usize,
    out_key: [*c]u8,
) c_int;

pub extern fn HKDF(
    out_key: [*c]u8,
    out_len: usize,
    digest: *const EVP_MD,
    secret: [*c]const u8,
    secret_len: usize,
    salt: [*c]const u8,
    salt_len: usize,
    info: [*c]const u8,
    info_len: usize,
) c_int;

pub const X25519_PRIVATE_KEY_LEN = 32;
pub const X25519_PUBLIC_VALUE_LEN = 32;

pub extern fn X25519_keypair(out_public_value: *[32]u8, out_private_key: *[32]u8) void;

pub const struct_ec_point_st = opaque {};
pub const EC_POINT = struct_ec_point_st;

pub const EVP_CIPHER = opaque {};
pub const EVP_CIPHER_CTX = opaque {};

pub extern fn EVP_aes_128_cbc() *const EVP_CIPHER;
pub extern fn EVP_aes_192_cbc() *const EVP_CIPHER;
pub extern fn EVP_aes_256_cbc() *const EVP_CIPHER;
pub extern fn EVP_aes_128_ctr() *const EVP_CIPHER;
pub extern fn EVP_aes_192_ctr() *const EVP_CIPHER;
pub extern fn EVP_aes_256_ctr() *const EVP_CIPHER;
pub extern fn EVP_aes_128_gcm() *const EVP_CIPHER;
pub extern fn EVP_aes_192_gcm() *const EVP_CIPHER;
pub extern fn EVP_aes_256_gcm() *const EVP_CIPHER;

pub extern fn EVP_CIPHER_CTX_new() ?*EVP_CIPHER_CTX;
pub extern fn EVP_CIPHER_CTX_free(ctx: ?*EVP_CIPHER_CTX) void;
pub extern fn EVP_CIPHER_CTX_ctrl(ctx: *EVP_CIPHER_CTX, command: c_int, arg: c_int, ptr: ?*anyopaque) c_int;
pub extern fn EVP_CIPHER_CTX_set_padding(ctx: *EVP_CIPHER_CTX, padding: c_int) c_int;

pub extern fn EVP_EncryptInit_ex(ctx: *EVP_CIPHER_CTX, cipher: ?*const EVP_CIPHER, impl: ?*ENGINE, key: [*c]const u8, iv: [*c]const u8) c_int;
pub extern fn EVP_EncryptUpdate(ctx: *EVP_CIPHER_CTX, out: [*c]u8, out_len: *c_int, in: [*c]const u8, in_len: c_int) c_int;
pub extern fn EVP_EncryptFinal_ex(ctx: *EVP_CIPHER_CTX, out: [*c]u8, out_len: *c_int) c_int;
pub extern fn EVP_DecryptInit_ex(ctx: *EVP_CIPHER_CTX, cipher: ?*const EVP_CIPHER, impl: ?*ENGINE, key: [*c]const u8, iv: [*c]const u8) c_int;
pub extern fn EVP_DecryptUpdate(ctx: *EVP_CIPHER_CTX, out: [*c]u8, out_len: *c_int, in: [*c]const u8, in_len: c_int) c_int;
pub extern fn EVP_DecryptFinal_ex(ctx: *EVP_CIPHER_CTX, out: [*c]u8, out_len: *c_int) c_int;

// EVP_CIPHER_CTX_ctrl commands for AES-GCM.
pub const EVP_CTRL_GCM_SET_IVLEN = 0x9;
pub const EVP_CTRL_GCM_GET_TAG = 0x10;
pub const EVP_CTRL_GCM_SET_TAG = 0x11;

// EC key type + curve identifiers.
pub const EVP_PKEY_EC = 408; // NID_X9_62_id_ecPublicKey
pub const NID_X9_62_prime256v1 = 415; // P-256
pub const NID_secp384r1 = 715; // P-384
pub const NID_secp521r1 = 716; // P-521

pub extern fn EVP_PKEY_new() ?*EVP_PKEY;
pub extern fn EVP_PKEY_id(pkey: *const EVP_PKEY) c_int;
pub extern fn EVP_PKEY_set1_EC_KEY(pkey: *EVP_PKEY, key: *EC_KEY) c_int;

pub extern fn EC_KEY_new_by_curve_name(nid: c_int) ?*EC_KEY;
pub extern fn EC_KEY_generate_key(key: *EC_KEY) c_int;
pub extern fn EC_KEY_free(key: ?*EC_KEY) void;
pub extern fn EC_KEY_get0_public_key(key: *const EC_KEY) ?*const EC_POINT;
pub extern fn EC_KEY_set_public_key(key: *EC_KEY, point: *const EC_POINT) c_int;

// DER decoders (advance `inp` past the parsed structure).
pub extern fn d2i_PUBKEY(out: ?*?*EVP_PKEY, inp: *[*c]const u8, len: c_long) ?*EVP_PKEY;
pub extern fn d2i_AutoPrivateKey(out: ?*?*EVP_PKEY, inp: *[*c]const u8, len: c_long) ?*EVP_PKEY;

pub const NID_X25519 = @as(c_int, 948);
pub const EVP_PKEY_X25519 = NID_X25519;
pub const NID_ED25519 = 949;
pub const EVP_PKEY_ED25519 = NID_ED25519;

pub extern fn EVP_PKEY_new_raw_private_key(@"type": c_int, unused: ?*ENGINE, in: [*c]const u8, len: usize) ?*EVP_PKEY;
pub extern fn EVP_PKEY_new_raw_public_key(@"type": c_int, unused: ?*ENGINE, in: [*c]const u8, len: usize) ?*EVP_PKEY;
pub extern fn EVP_PKEY_CTX_new(pkey: ?*EVP_PKEY, e: ?*ENGINE) ?*EVP_PKEY_CTX;
pub extern fn EVP_PKEY_CTX_free(ctx: ?*EVP_PKEY_CTX) void;
pub extern fn EVP_PKEY_derive_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_derive(ctx: ?*EVP_PKEY_CTX, key: [*c]u8, out_key_len: [*c]usize) c_int;
pub extern fn EVP_PKEY_derive_set_peer(ctx: ?*EVP_PKEY_CTX, peer: ?*EVP_PKEY) c_int;
pub extern fn EVP_PKEY_free(pkey: ?*EVP_PKEY) void;

pub extern fn EVP_DigestSignInit(ctx: ?*EVP_MD_CTX, pctx: ?*?*EVP_PKEY_CTX, typ: ?*const EVP_MD, e: ?*ENGINE, pkey: ?*EVP_PKEY) c_int;
pub extern fn EVP_DigestSign(ctx: ?*EVP_MD_CTX, sig: [*c]u8, sig_len: *usize, data: [*c]const u8, data_len: usize) c_int;
pub extern fn EVP_Digest(data: ?*const anyopaque, len: usize, md_out: [*c]u8, md_out_size: [*c]c_uint, @"type": ?*const EVP_MD, impl: ?*ENGINE) c_int;
pub extern fn EVP_MD_CTX_new() ?*EVP_MD_CTX;
pub extern fn EVP_MD_CTX_free(ctx: ?*EVP_MD_CTX) void;
pub const struct_evp_md_ctx_st = opaque {};
pub const EVP_MD_CTX = struct_evp_md_ctx_st;

pub const struct_x509_st = opaque {};
pub const X509 = struct_x509_st;

pub extern fn X509_free(x509: ?*X509) void;
pub extern fn d2i_X509(out: [*c]?*X509, inp: *[*]const u8, len: c_long) ?*X509;

pub const struct_x509_store_st = opaque {};
pub const X509_STORE = struct_x509_store_st;

pub extern fn X509_STORE_new() ?*X509_STORE;
pub extern fn X509_STORE_free(store: *X509_STORE) void;
pub extern fn X509_STORE_add_cert(store: ?*X509_STORE, x: ?*X509) c_int;
pub extern fn X509_STORE_load_locations(store: *X509_STORE, file: ?[*:0]const u8, dir: ?[*:0]const u8) c_int;

pub const struct_ssl_ctx_st = opaque {};
pub const SSL_CTX = struct_ssl_ctx_st;
pub extern fn SSL_CTX_set1_verify_cert_store(ctx: ?*SSL_CTX, store: ?*X509_STORE) c_int;

/// Returns the desired digest by its name.
pub fn findDigest(name: []const u8) error{Invalid}!*const EVP_MD {
    if (std.mem.eql(u8, "SHA-256", name)) {
        return EVP_sha256();
    }

    if (std.mem.eql(u8, "SHA-384", name)) {
        return EVP_sha384();
    }

    if (std.mem.eql(u8, "SHA-512", name)) {
        return EVP_sha512();
    }

    if (std.mem.eql(u8, "SHA-1", name)) {
        return EVP_sha1();
    }

    return error.Invalid;
}

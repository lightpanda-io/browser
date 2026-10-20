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

const struct_env_md_st = opaque {};
pub const EVP_MD = struct_env_md_st;
const struct_engine_st = opaque {};
const ENGINE = struct_engine_st;
const struct_ec_key_st = opaque {};
pub const EC_KEY = struct_ec_key_st;
const struct_evp_pkey_st = opaque {};
pub const EVP_PKEY = struct_evp_pkey_st;
const struct_evp_pkey_ctx_st = opaque {};
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

pub extern fn ERR_clear_error() void;

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

const struct_ec_point_st = opaque {};
const EC_POINT = struct_ec_point_st;

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

// AES key wrap (RFC 3394), for AES-KW. `AES_KEY` must match BoringSSL's
// `struct aes_key_st` (AES_MAXNR = 14).
pub const AES_KEY = extern struct {
    rd_key: [4 * (14 + 1)]u32,
    rounds: c_uint,
};
/// Returns 0 on success, negative for an invalid key size.
pub extern fn AES_set_encrypt_key(key: [*]const u8, bits: c_uint, aeskey: *AES_KEY) c_int;
pub extern fn AES_set_decrypt_key(key: [*]const u8, bits: c_uint, aeskey: *AES_KEY) c_int;
/// Returns the output length (`in_len` + 8 / - 8), or -1. A null `iv` is the
/// default IV.
pub extern fn AES_wrap_key(key: *const AES_KEY, iv: ?[*]const u8, out: [*]u8, in: [*]const u8, in_len: usize) c_int;
pub extern fn AES_unwrap_key(key: *const AES_KEY, iv: ?[*]const u8, out: [*]u8, in: [*]const u8, in_len: usize) c_int;

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
pub extern fn EVP_PKEY_bits(pkey: *const EVP_PKEY) c_int;
pub extern fn EVP_PKEY_set1_EC_KEY(pkey: *EVP_PKEY, key: *EC_KEY) c_int;

pub extern fn EC_KEY_new_by_curve_name(nid: c_int) ?*EC_KEY;
pub extern fn EC_KEY_generate_key(key: *EC_KEY) c_int;
pub extern fn EC_KEY_free(key: ?*EC_KEY) void;
pub extern fn EC_KEY_get0_public_key(key: *const EC_KEY) ?*const EC_POINT;
pub extern fn EC_KEY_set_public_key(key: *EC_KEY, point: *const EC_POINT) c_int;
pub extern fn EC_KEY_get0_private_key(key: *const EC_KEY) ?*const BIGNUM;
pub extern fn EC_KEY_set_private_key(key: *EC_KEY, priv: *const BIGNUM) c_int;
/// 1 when the public key is a valid point (not infinity) and matches the
/// private key, if any.
pub extern fn EC_KEY_check_key(key: *const EC_KEY) c_int;
pub extern fn EVP_PKEY_get0_EC_KEY(pkey: *const EVP_PKEY) ?*EC_KEY;
const struct_ec_group_st = opaque {};
const EC_GROUP = struct_ec_group_st;
pub extern fn EC_KEY_get0_group(key: *const EC_KEY) ?*const EC_GROUP;
pub extern fn EC_GROUP_get0_order(group: *const EC_GROUP) ?*const BIGNUM;
pub extern fn EC_GROUP_get_curve_name(group: *const EC_GROUP) c_int;

// SEC 1 point encodings: 0x04 || x || y, or compressed 0x02/0x03 || x.
pub const POINT_CONVERSION_UNCOMPRESSED = 4;
pub extern fn EC_POINT_new(group: *const EC_GROUP) ?*EC_POINT;
pub extern fn EC_POINT_free(point: ?*EC_POINT) void;
/// Fails for an encoding that isn't a point on the curve.
pub extern fn EC_POINT_oct2point(group: *const EC_GROUP, point: *EC_POINT, buf: [*]const u8, len: usize, ctx: ?*anyopaque) c_int;
/// With a null `buf`, returns the encoding's length; 0 on error.
pub extern fn EC_POINT_point2oct(group: *const EC_GROUP, point: *const EC_POINT, form: c_int, buf: ?[*]u8, len: usize, ctx: ?*anyopaque) usize;

// ECDSA over a digest, with the signature as an (r, s) pair.
const struct_ecdsa_sig_st = opaque {};
pub const ECDSA_SIG = struct_ecdsa_sig_st;
pub extern fn ECDSA_do_sign(digest: [*]const u8, digest_len: usize, key: *const EC_KEY) ?*ECDSA_SIG;
/// Returns 1 for a valid signature, 0 otherwise (on the error queue).
pub extern fn ECDSA_do_verify(digest: [*]const u8, digest_len: usize, sig: *const ECDSA_SIG, key: *const EC_KEY) c_int;
pub extern fn ECDSA_SIG_new() ?*ECDSA_SIG;
pub extern fn ECDSA_SIG_free(sig: ?*ECDSA_SIG) void;
pub extern fn ECDSA_SIG_get0(sig: *const ECDSA_SIG, out_r: *?*const BIGNUM, out_s: *?*const BIGNUM) void;
/// Takes ownership of `r` and `s` on success only.
pub extern fn ECDSA_SIG_set0(sig: *ECDSA_SIG, r: *BIGNUM, s: *BIGNUM) c_int;

// DER decoders over a CBS (a byte string cursor, advanced past the parsed
// structure). Unlike the d2i_* family, these parse exactly one SubjectPublicKeyInfo
// or PrivateKeyInfo: no legacy RSAPrivateKey / ECPrivateKey fallback.
pub const CBS = extern struct {
    data: [*]const u8,
    len: usize,
};
pub extern fn EVP_parse_public_key(cbs: *CBS) ?*EVP_PKEY;
pub extern fn EVP_parse_private_key(cbs: *CBS) ?*EVP_PKEY;

// RSA: key generation, import, and the encrypt/decrypt and sign/verify operations.
pub const EVP_PKEY_RSA = 6; // NID_rsaEncryption
pub const RSA_PKCS1_PADDING = 1;
pub const RSA_PKCS1_OAEP_PADDING = 4;
pub const RSA_PKCS1_PSS_PADDING = 6;

const struct_rsa_st = opaque {};
pub const RSA = struct_rsa_st;
const struct_bignum_st = opaque {};
pub const BIGNUM = struct_bignum_st;

pub extern fn RSA_new() ?*RSA;
pub extern fn RSA_free(rsa: ?*RSA) void;
pub extern fn RSA_generate_key_ex(rsa: *RSA, bits: c_int, e: *const BIGNUM, cb: ?*anyopaque) c_int;
pub extern fn RSAPublicKey_dup(rsa: *const RSA) ?*RSA;
pub extern fn EVP_PKEY_set1_RSA(pkey: *EVP_PKEY, key: *RSA) c_int;
pub extern fn EVP_PKEY_get0_RSA(pkey: *const EVP_PKEY) ?*RSA;
pub extern fn RSA_get0_n(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_e(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_d(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_p(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_q(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_dmp1(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_dmq1(rsa: *const RSA) ?*const BIGNUM;
pub extern fn RSA_get0_iqmp(rsa: *const RSA) ?*const BIGNUM;
// Build a key from its components; NULL on error or an invalid (inconsistent) key.
pub extern fn RSA_new_public_key(n: *const BIGNUM, e: *const BIGNUM) ?*RSA;
pub extern fn RSA_new_private_key(
    n: *const BIGNUM,
    e: *const BIGNUM,
    d: *const BIGNUM,
    p: *const BIGNUM,
    q: *const BIGNUM,
    dmp1: *const BIGNUM,
    dmq1: *const BIGNUM,
    iqmp: *const BIGNUM,
) ?*RSA;

// DER encoders. With `*outp == null`, libcrypto allocates the output (release
// it with OPENSSL_free) and stores it in `*outp`. Returns the length, or a
// negative value on error.
const struct_pkcs8_priv_key_info_st = opaque {};
pub const PKCS8_PRIV_KEY_INFO = struct_pkcs8_priv_key_info_st;
pub extern fn i2d_PUBKEY(pkey: *const EVP_PKEY, outp: *[*c]u8) c_int;
pub extern fn EVP_PKEY2PKCS8(pkey: *const EVP_PKEY) ?*PKCS8_PRIV_KEY_INFO;
pub extern fn i2d_PKCS8_PRIV_KEY_INFO(key: *const PKCS8_PRIV_KEY_INFO, outp: *[*c]u8) c_int;
pub extern fn PKCS8_PRIV_KEY_INFO_free(key: ?*PKCS8_PRIV_KEY_INFO) void;

pub extern fn BN_new() ?*BIGNUM;
pub extern fn BN_free(bn: ?*BIGNUM) void;
pub extern fn BN_bin2bn(in: [*c]const u8, len: usize, ret: ?*BIGNUM) ?*BIGNUM;
pub extern fn BN_num_bytes(bn: *const BIGNUM) c_uint;
pub extern fn BN_bn2bin(in: *const BIGNUM, out: [*]u8) usize;
/// Big-endian, left-padded with zeros to exactly `len` bytes; 0 if it doesn't fit.
pub extern fn BN_bn2bin_padded(out: [*]u8, len: usize, in: *const BIGNUM) c_int;

pub extern fn OPENSSL_malloc(size: usize) ?*anyopaque;
pub extern fn OPENSSL_free(ptr: ?*anyopaque) void;

pub extern fn EVP_PKEY_encrypt_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_encrypt(ctx: ?*EVP_PKEY_CTX, out: [*c]u8, out_len: *usize, in: [*c]const u8, in_len: usize) c_int;
pub extern fn EVP_PKEY_decrypt_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_decrypt(ctx: ?*EVP_PKEY_CTX, out: [*c]u8, out_len: *usize, in: [*c]const u8, in_len: usize) c_int;
pub extern fn EVP_PKEY_CTX_set_rsa_padding(ctx: ?*EVP_PKEY_CTX, padding: c_int) c_int;
pub extern fn EVP_PKEY_CTX_set_rsa_oaep_md(ctx: ?*EVP_PKEY_CTX, md: *const EVP_MD) c_int;
pub extern fn EVP_PKEY_CTX_set_rsa_mgf1_md(ctx: ?*EVP_PKEY_CTX, md: *const EVP_MD) c_int;
/// Negative values are special: -1 is the digest's length; -2 is the maximum
/// when signing, and any length (read from the signature) when verifying.
pub extern fn EVP_PKEY_CTX_set_rsa_pss_saltlen(ctx: ?*EVP_PKEY_CTX, salt_len: c_int) c_int;
/// Takes ownership of `label` (an OPENSSL_malloc buffer) on success only.
pub extern fn EVP_PKEY_CTX_set0_rsa_oaep_label(ctx: ?*EVP_PKEY_CTX, label: [*]u8, label_len: usize) c_int;

const NID_X25519 = @as(c_int, 948);
pub const EVP_PKEY_X25519 = NID_X25519;
const NID_ED25519 = 949;
pub const EVP_PKEY_ED25519 = NID_ED25519;

pub extern fn EVP_PKEY_new_raw_private_key(@"type": c_int, unused: ?*ENGINE, in: [*c]const u8, len: usize) ?*EVP_PKEY;
pub extern fn EVP_PKEY_new_raw_public_key(@"type": c_int, unused: ?*ENGINE, in: [*c]const u8, len: usize) ?*EVP_PKEY;
/// With `out` null, sets `out_len` to the key's size; otherwise writes it.
pub extern fn EVP_PKEY_get_raw_private_key(pkey: *const EVP_PKEY, out: [*c]u8, out_len: *usize) c_int;
pub extern fn EVP_PKEY_get_raw_public_key(pkey: *const EVP_PKEY, out: [*c]u8, out_len: *usize) c_int;

pub const ED25519_PUBLIC_KEY_LEN = 32;
/// BoringSSL's Ed25519 private key: the 32-byte seed, then the public key.
pub const ED25519_PRIVATE_KEY_LEN = 64;
pub const ED25519_SIGNATURE_LEN = 64;
pub extern fn ED25519_keypair(out_public_key: *[ED25519_PUBLIC_KEY_LEN]u8, out_private_key: *[ED25519_PRIVATE_KEY_LEN]u8) void;
pub extern fn EVP_PKEY_CTX_new(pkey: ?*EVP_PKEY, e: ?*ENGINE) ?*EVP_PKEY_CTX;
pub extern fn EVP_PKEY_CTX_free(ctx: ?*EVP_PKEY_CTX) void;
pub extern fn EVP_PKEY_derive_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_derive(ctx: ?*EVP_PKEY_CTX, key: [*c]u8, out_key_len: [*c]usize) c_int;
pub extern fn EVP_PKEY_derive_set_peer(ctx: ?*EVP_PKEY_CTX, peer: ?*EVP_PKEY) c_int;
pub extern fn EVP_PKEY_free(pkey: ?*EVP_PKEY) void;

pub extern fn EVP_DigestSignInit(ctx: ?*EVP_MD_CTX, pctx: ?*?*EVP_PKEY_CTX, typ: ?*const EVP_MD, e: ?*ENGINE, pkey: ?*EVP_PKEY) c_int;
pub extern fn EVP_DigestSign(ctx: ?*EVP_MD_CTX, sig: [*c]u8, sig_len: *usize, data: [*c]const u8, data_len: usize) c_int;
pub extern fn EVP_DigestVerifyInit(ctx: ?*EVP_MD_CTX, pctx: ?*?*EVP_PKEY_CTX, typ: ?*const EVP_MD, e: ?*ENGINE, pkey: ?*EVP_PKEY) c_int;
/// Returns 1 for a valid signature, 0 otherwise (on the error queue).
pub extern fn EVP_DigestVerify(ctx: ?*EVP_MD_CTX, sig: [*c]const u8, sig_len: usize, data: [*c]const u8, data_len: usize) c_int;
pub extern fn EVP_Digest(data: ?*const anyopaque, len: usize, md_out: [*c]u8, md_out_size: [*c]c_uint, @"type": ?*const EVP_MD, impl: ?*ENGINE) c_int;
pub extern fn EVP_MD_CTX_new() ?*EVP_MD_CTX;
pub extern fn EVP_MD_CTX_free(ctx: ?*EVP_MD_CTX) void;
const struct_evp_md_ctx_st = opaque {};
pub const EVP_MD_CTX = struct_evp_md_ctx_st;

const struct_x509_st = opaque {};
pub const X509 = struct_x509_st;

pub extern fn X509_free(x509: ?*X509) void;
pub extern fn d2i_X509(out: [*c]?*X509, inp: *[*]const u8, len: c_long) ?*X509;

const struct_x509_store_st = opaque {};
pub const X509_STORE = struct_x509_store_st;

pub extern fn X509_STORE_new() ?*X509_STORE;
pub extern fn X509_STORE_free(store: *X509_STORE) void;
pub extern fn X509_STORE_add_cert(store: ?*X509_STORE, x: ?*X509) c_int;
pub extern fn X509_STORE_load_locations(store: *X509_STORE, file: ?[*:0]const u8, dir: ?[*:0]const u8) c_int;

const struct_ssl_ctx_st = opaque {};
pub const SSL_CTX = struct_ssl_ctx_st;
pub extern fn SSL_CTX_set1_verify_cert_store(ctx: ?*SSL_CTX, store: ?*X509_STORE) c_int;
pub extern fn SSL_CTX_new(method: *const SSL_METHOD) ?*SSL_CTX;
pub extern fn SSL_CTX_free(ctx: *SSL_CTX) void;
pub extern fn SSL_CTX_set1_curves_list(ctx: *SSL_CTX, curves: [*:0]const u8) c_int;

const struct_ssl_method_st = opaque {};
pub const SSL_METHOD = struct_ssl_method_st;
pub extern fn TLS_method() *const SSL_METHOD;

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

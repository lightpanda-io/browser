//! libcrypto utilities we use throughout browser.

const std = @import("std");

const pthread_rwlock_t = std.c.pthread_rwlock_t;

pub const struct_env_md_st = opaque {};
pub const EVP_MD = struct_env_md_st;
pub const evp_pkey_alg_st = opaque {};
pub const EVP_PKEY_ALG = evp_pkey_alg_st;
pub const struct_engine_st = opaque {};
pub const ENGINE = struct_engine_st;
pub const CRYPTO_THREADID = c_int;
pub const struct_asn1_null_st = opaque {};
pub const ASN1_NULL = struct_asn1_null_st;
pub const ASN1_BOOLEAN = c_int;
pub const struct_ASN1_ITEM_st = opaque {};
pub const ASN1_ITEM = struct_ASN1_ITEM_st;
pub const struct_asn1_object_st = opaque {};
pub const ASN1_OBJECT = struct_asn1_object_st;
pub const struct_asn1_pctx_st = opaque {};
pub const ASN1_PCTX = struct_asn1_pctx_st;
pub const struct_asn1_string_st = extern struct {
    length: c_int,
    type: c_int,
    data: [*c]u8,
    flags: c_long,
};
pub const ASN1_BIT_STRING = struct_asn1_string_st;
pub const ASN1_BMPSTRING = struct_asn1_string_st;
pub const ASN1_ENUMERATED = struct_asn1_string_st;
pub const ASN1_GENERALIZEDTIME = struct_asn1_string_st;
pub const ASN1_GENERALSTRING = struct_asn1_string_st;
pub const ASN1_IA5STRING = struct_asn1_string_st;
pub const ASN1_INTEGER = struct_asn1_string_st;
pub const ASN1_OCTET_STRING = struct_asn1_string_st;
pub const ASN1_PRINTABLESTRING = struct_asn1_string_st;
pub const ASN1_STRING = struct_asn1_string_st;
pub const ASN1_T61STRING = struct_asn1_string_st;
pub const ASN1_TIME = struct_asn1_string_st;
pub const ASN1_UNIVERSALSTRING = struct_asn1_string_st;
pub const ASN1_UTCTIME = struct_asn1_string_st;
pub const ASN1_UTF8STRING = struct_asn1_string_st;
pub const ASN1_VISIBLESTRING = struct_asn1_string_st;
pub const struct_ASN1_VALUE_st = opaque {};
pub const ASN1_VALUE = struct_ASN1_VALUE_st;
const union_unnamed_1 = extern union {
    ptr: [*c]u8,
    boolean: ASN1_BOOLEAN,
    asn1_string: [*c]ASN1_STRING,
    object: ?*ASN1_OBJECT,
    integer: [*c]ASN1_INTEGER,
    enumerated: [*c]ASN1_ENUMERATED,
    bit_string: [*c]ASN1_BIT_STRING,
    octet_string: [*c]ASN1_OCTET_STRING,
    printablestring: [*c]ASN1_PRINTABLESTRING,
    t61string: [*c]ASN1_T61STRING,
    ia5string: [*c]ASN1_IA5STRING,
    generalstring: [*c]ASN1_GENERALSTRING,
    bmpstring: [*c]ASN1_BMPSTRING,
    universalstring: [*c]ASN1_UNIVERSALSTRING,
    utctime: [*c]ASN1_UTCTIME,
    generalizedtime: [*c]ASN1_GENERALIZEDTIME,
    visiblestring: [*c]ASN1_VISIBLESTRING,
    utf8string: [*c]ASN1_UTF8STRING,
    set: [*c]ASN1_STRING,
    sequence: [*c]ASN1_STRING,
    asn1_value: ?*ASN1_VALUE,
};
pub const struct_asn1_type_st = extern struct {
    type: c_int,
    value: union_unnamed_1,
};
pub const ASN1_TYPE = struct_asn1_type_st;
pub const struct_AUTHORITY_KEYID_st = opaque {};
pub const AUTHORITY_KEYID = struct_AUTHORITY_KEYID_st;
pub const struct_BASIC_CONSTRAINTS_st = opaque {};
pub const BASIC_CONSTRAINTS = struct_BASIC_CONSTRAINTS_st;
pub const struct_DIST_POINT_st = opaque {};
pub const DIST_POINT = struct_DIST_POINT_st;
pub const BN_ULONG = u64;
pub const struct_bignum_st = extern struct {
    d: [*c]BN_ULONG,
    width: c_int,
    dmax: c_int,
    neg: c_int,
    flags: c_int,
};
pub const BIGNUM = struct_bignum_st;
pub const struct_DSA_SIG_st = extern struct {
    r: [*c]BIGNUM,
    s: [*c]BIGNUM,
};
pub const DSA_SIG = struct_DSA_SIG_st;
pub const struct_ISSUING_DIST_POINT_st = opaque {};
pub const ISSUING_DIST_POINT = struct_ISSUING_DIST_POINT_st;
pub const struct_NAME_CONSTRAINTS_st = opaque {};
pub const NAME_CONSTRAINTS = struct_NAME_CONSTRAINTS_st;
pub const struct_X509_pubkey_st = opaque {};
pub const X509_PUBKEY = struct_X509_pubkey_st;
pub const struct_Netscape_spkac_st = extern struct {
    pubkey: ?*X509_PUBKEY,
    challenge: [*c]ASN1_IA5STRING,
};
pub const NETSCAPE_SPKAC = struct_Netscape_spkac_st;
pub const struct_X509_algor_st = extern struct {
    algorithm: ?*ASN1_OBJECT,
    parameter: [*c]ASN1_TYPE,
};
pub const X509_ALGOR = struct_X509_algor_st;
pub const struct_Netscape_spki_st = extern struct {
    spkac: [*c]NETSCAPE_SPKAC,
    sig_algor: [*c]X509_ALGOR,
    signature: [*c]ASN1_BIT_STRING,
};
pub const NETSCAPE_SPKI = struct_Netscape_spki_st;
pub const struct_RIPEMD160state_st = opaque {};
pub const RIPEMD160_CTX = struct_RIPEMD160state_st;
pub const struct_X509_VERIFY_PARAM_st = opaque {};
pub const X509_VERIFY_PARAM = struct_X509_VERIFY_PARAM_st;
pub const struct_X509_crl_st = opaque {};
pub const X509_CRL = struct_X509_crl_st;
pub const struct_X509_extension_st = opaque {};
pub const X509_EXTENSION = struct_X509_extension_st;
pub const struct_x509_st = opaque {};
pub const X509 = struct_x509_st;
pub const CRYPTO_refcount_t = u32;
pub const struct_openssl_method_common_st = extern struct {
    references: c_int,
    is_static: u8,
};
pub const struct_rsa_meth_st = extern struct {
    common: struct_openssl_method_common_st,
    app_data: ?*anyopaque,
    init: ?*const fn (?*RSA) callconv(.c) c_int,
    finish: ?*const fn (?*RSA) callconv(.c) c_int,
    size: ?*const fn (?*const RSA) callconv(.c) usize,
    sign: ?*const fn (c_int, [*c]const u8, c_uint, [*c]u8, [*c]c_uint, ?*const RSA) callconv(.c) c_int,
    sign_raw: ?*const fn (?*RSA, [*c]usize, [*c]u8, usize, [*c]const u8, usize, c_int) callconv(.c) c_int,
    decrypt: ?*const fn (?*RSA, [*c]usize, [*c]u8, usize, [*c]const u8, usize, c_int) callconv(.c) c_int,
    private_transform: ?*const fn (?*RSA, [*c]u8, [*c]const u8, usize) callconv(.c) c_int,
    flags: c_int,
};
pub const RSA_METHOD = struct_rsa_meth_st;
pub const struct_stack_st_void = opaque {};
pub const struct_crypto_ex_data_st = extern struct {
    sk: ?*struct_stack_st_void,
};
pub const CRYPTO_EX_DATA = struct_crypto_ex_data_st;
pub const CRYPTO_MUTEX = pthread_rwlock_t;
pub const struct_bn_mont_ctx_st = extern struct {
    RR: BIGNUM,
    N: BIGNUM,
    n0: [2]BN_ULONG,
};
pub const BN_MONT_CTX = struct_bn_mont_ctx_st;
pub const struct_bn_blinding_st = opaque {};
pub const BN_BLINDING = struct_bn_blinding_st; // boringssl/include/openssl/rsa.h:788:12: warning: struct demoted to opaque type - has bitfield
pub const struct_rsa_st = opaque {};
pub const RSA = struct_rsa_st;
pub const struct_dsa_st = extern struct {
    version: c_long,
    p: [*c]BIGNUM,
    q: [*c]BIGNUM,
    g: [*c]BIGNUM,
    pub_key: [*c]BIGNUM,
    priv_key: [*c]BIGNUM,
    flags: c_int,
    method_mont_lock: CRYPTO_MUTEX,
    method_mont_p: [*c]BN_MONT_CTX,
    method_mont_q: [*c]BN_MONT_CTX,
    references: CRYPTO_refcount_t,
    ex_data: CRYPTO_EX_DATA,
};
pub const DSA = struct_dsa_st;
pub const struct_dh_st = opaque {};
pub const DH = struct_dh_st;
pub const struct_ec_key_st = opaque {};
pub const EC_KEY = struct_ec_key_st;
const union_unnamed_2 = extern union {
    ptr: ?*anyopaque,
    rsa: ?*RSA,
    dsa: [*c]DSA,
    dh: ?*DH,
    ec: ?*EC_KEY,
};
pub const struct_evp_pkey_asn1_method_st = opaque {};
pub const EVP_PKEY_ASN1_METHOD = struct_evp_pkey_asn1_method_st;
pub const struct_evp_pkey_st = extern struct {
    references: CRYPTO_refcount_t,
    type: c_int,
    pkey: union_unnamed_2,
    ameth: ?*const EVP_PKEY_ASN1_METHOD,
};
pub const EVP_PKEY = struct_evp_pkey_st;
pub const struct_evp_pkey_ctx_st = opaque {};
pub const EVP_PKEY_CTX = struct_evp_pkey_ctx_st;

pub extern fn RAND_bytes(buf: [*]u8, len: usize) c_int;

pub extern fn EVP_sha1() *const EVP_MD;
pub extern fn EVP_sha256() *const EVP_MD;
pub extern fn EVP_sha384() *const EVP_MD;
pub extern fn EVP_sha512() *const EVP_MD;

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

pub const X25519_PRIVATE_KEY_LEN = 32;
pub const X25519_PUBLIC_VALUE_LEN = 32;
pub const X25519_SHARED_KEY_LEN = 32;

pub extern fn X25519_keypair(out_public_value: *[32]u8, out_private_key: *[32]u8) void;

pub const NID_X25519 = @as(c_int, 948);
pub const EVP_PKEY_X25519 = NID_X25519;

pub extern fn EVP_PKEY_new_raw_private_key(@"type": c_int, unused: ?*ENGINE, in: [*c]const u8, len: usize) [*c]EVP_PKEY;
pub extern fn EVP_PKEY_new_raw_public_key(@"type": c_int, unused: ?*ENGINE, in: [*c]const u8, len: usize) [*c]EVP_PKEY;
pub extern fn EVP_PKEY_CTX_new(pkey: [*c]EVP_PKEY, e: ?*ENGINE) ?*EVP_PKEY_CTX;
pub extern fn EVP_PKEY_CTX_free(ctx: ?*EVP_PKEY_CTX) void;
pub extern fn EVP_PKEY_derive_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_derive(ctx: ?*EVP_PKEY_CTX, key: [*c]u8, out_key_len: [*c]usize) c_int;
pub extern fn EVP_PKEY_derive_set_peer(ctx: ?*EVP_PKEY_CTX, peer: [*c]EVP_PKEY) c_int;

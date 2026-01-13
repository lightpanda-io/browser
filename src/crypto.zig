//! libcrypto utilities we use throughout browser.

pub const struct_env_md_st = opaque {};
pub const EVP_MD = struct_env_md_st;

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

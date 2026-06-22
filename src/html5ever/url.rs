// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// WHATWG "domain to ASCII" backed by the `idna` crate (UTS#46, the same engine
// rust-url/Servo use). Pairs with src/sys/idna.zig. Replaced libidn2, whose
// IDNA-2008 behavior diverged from the spec. Value-in / value-out: a UTF-8
// host string becomes its punycode form, or an error.

use ::url::Url;
use encoding_rs::{EncoderResult, Encoding};
use std::borrow::Cow;
use std::os::raw::c_uchar;
use std::slice;

fn str_from(ptr: *const c_uchar, len: usize) -> Option<&'static str> {
    // Zig hands empty slices a non-null but dangling pointer, so length must
    // be checked before forming a slice from raw parts.
    if ptr.is_null() || len == 0 {
        return Some("");
    }
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).ok()
}

// Catch any panic from the IDNA code so it never unwinds across the extern "C"
// boundary and aborts the whole process; a panic becomes error code 1.
fn ffi_guard<F: FnOnce() -> i32>(f: F) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(1)
}

/// WHATWG "domain to ASCII" (UTS#46, non-transitional, beStrict=false). Writes
/// a NUL-terminated owned buffer to *out_ptr / *out_len (caller frees with
/// lpurl_free). Returns 0 on success, 1 if `host` is not a valid domain.
#[no_mangle]
pub extern "C" fn lpurl_domain_to_ascii(
    host_ptr: *const c_uchar,
    host_len: usize,
    out_ptr: *mut *mut c_uchar,
    out_len: *mut usize,
) -> i32 {
    ffi_guard(move || {
        let host = match str_from(host_ptr, host_len) {
            Some(s) => s,
            None => return 1,
        };
        let ascii = match idna::domain_to_ascii(host) {
            Ok(s) => s,
            Err(_) => return 1,
        };
        let len = ascii.len();
        let mut bytes = ascii.into_bytes();
        bytes.push(0);
        let boxed = bytes.into_boxed_slice();
        unsafe {
            *out_ptr = Box::into_raw(boxed) as *mut c_uchar;
            *out_len = len;
        }
        0
    })
}

/// Free a NUL-terminated buffer handed out by lpurl_domain_to_ascii.
#[no_mangle]
pub extern "C" fn lpurl_free(ptr: *mut c_uchar, len: usize) {
    if ptr.is_null() {
        return;
    }
    // The buffer included a NUL terminator, so its length is len + 1 and its
    // capacity matches exactly (it was a boxed slice).
    unsafe {
        let slice = std::ptr::slice_from_raw_parts_mut(ptr, len + 1);
        drop(Box::from_raw(slice));
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_parse(ptr: *const c_uchar, len: usize, err: *mut i32) -> *mut Url {
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => {
            *err = url::ParseError::EmptyHost as i32;
            return std::ptr::null_mut();
        }
    };

    match Url::parse(slice) {
        Ok(url) => Box::into_raw(Box::new(url)),
        Err(e) => {
            *err = e as i32;
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_parse_with_base(
    base_ptr: *const c_uchar,
    base_len: usize,
    ptr: *const c_uchar,
    len: usize,
    err: *mut i32,
) -> *mut Url {
    let base_slice = match str_from(base_ptr, base_len) {
        Some(s) => s,
        None => {
            *err = url::ParseError::EmptyHost as i32;
            return std::ptr::null_mut();
        }
    };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => {
            *err = url::ParseError::EmptyHost as i32;
            return std::ptr::null_mut();
        }
    };

    match Url::parse(base_slice) {
        Ok(base) => match base.join(slice) {
            Ok(url) => Box::into_raw(Box::new(url)),
            Err(e) => {
                *err = e as i32;
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            *err = e as i32;
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_join(
    base: *const Url,
    ptr: *const c_uchar,
    len: usize,
    err: *mut i32,
) -> *mut Url {
    let base = unsafe { &*base };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => {
            *err = url::ParseError::EmptyHost as i32;
            return std::ptr::null_mut();
        }
    };

    match base.join(slice) {
        Ok(url) => Box::into_raw(Box::new(url)),
        Err(e) => {
            *err = e as i32;
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_can_parse(ptr: *const c_uchar, len: usize) -> bool {
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return false,
    };

    Url::parse(slice).is_ok()
}

#[no_mangle]
pub unsafe extern "C" fn url_can_parse_with_base(
    base_ptr: *const c_uchar,
    base_len: usize,
    ptr: *const c_uchar,
    len: usize,
) -> bool {
    let base_slice = match str_from(base_ptr, base_len) {
        Some(s) => s,
        None => return false,
    };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return false,
    };

    match Url::parse(base_slice) {
        Ok(url) => url.join(slice).is_ok(),
        Err(_) => false,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_free(url: *mut Url) {
    if url.is_null() {
        return;
    }
    drop(Box::from_raw(url));
}

#[no_mangle]
pub unsafe extern "C" fn url_to_string(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) {
    let url = unsafe { &*url };
    let s = url.as_str();
    *out_ptr = s.as_ptr();
    *out_len = s.len();
}

#[no_mangle]
pub unsafe extern "C" fn url_set_username(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    match url.set_username(slice) {
        Ok(()) => 0,
        Err(()) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_username(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) {
    let url = unsafe { &*url };
    let username = url.username();
    *out_ptr = username.as_ptr();
    *out_len = username.len();
}

#[no_mangle]
pub unsafe extern "C" fn url_set_password(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    match url.set_password(Some(slice)) {
        Ok(()) => 0,
        Err(()) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_password(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) -> i32 {
    let url = unsafe { &*url };
    match url.password() {
        Some(password) => {
            *out_ptr = password.as_ptr();
            *out_len = password.len();
            0
        }
        None => -1,
    }
}

#[repr(C)]
pub struct OwnedString {
    pub ptr: *mut c_uchar,
    pub len: usize,
}

const EMPTY_OWNED_STRING: OwnedString = OwnedString {
    ptr: std::ptr::null_mut(),
    len: 0,
};

#[no_mangle]
pub unsafe extern "C" fn free_owned_string(owned: OwnedString) {
    if owned.ptr.is_null() || owned.len == 0 {
        return;
    }

    unsafe {
        let slice = std::ptr::slice_from_raw_parts_mut(owned.ptr, owned.len);
        drop(Box::from_raw(slice));
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_origin(url: *const Url) -> OwnedString {
    let url = unsafe { &*url };
    let origin = url.origin().ascii_serialization();
    let len = origin.len();
    let ptr = Box::into_raw(origin.into_bytes().into_boxed_slice()) as *mut c_uchar;
    OwnedString { ptr, len }
}

#[no_mangle]
pub unsafe extern "C" fn url_set_port(url: *mut Url, port: u16) -> i32 {
    let url = unsafe { &mut *url };
    match url.set_port(Some(port)) {
        Ok(()) => 0,
        Err(()) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_set_port_to_null(url: *mut Url) -> i32 {
    let url = unsafe { &mut *url };
    match url.set_port(None) {
        Ok(()) => 0,
        Err(()) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_port(url: *const Url) -> i32 {
    let url = unsafe { &*url };
    match url.port() {
        Some(port) => port as i32,
        None => -1,
    }
}

fn clean_hostname_input(url: &Url, raw: &str) -> String {
    let special = matches!(
        url.scheme(),
        "http" | "https" | "ws" | "wss" | "ftp" | "file"
    );
    let mut out = String::with_capacity(raw.len());
    let mut in_brackets = false;
    for c in raw.chars() {
        match c {
            '\t' | '\n' | '\r' => continue,
            '[' => in_brackets = true,
            ']' => in_brackets = false,
            '/' | '?' | '#' => break,
            '\\' if special => break,
            ':' if !in_brackets => break,
            _ => {}
        }
        out.push(c);
    }
    out
}

/// WHATWG `hostname` setter: sets the host without touching the port.
#[no_mangle]
pub unsafe extern "C" fn url_set_hostname(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };

    let raw = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };
    let host = clean_hostname_input(url, raw);

    match url.set_host(Some(host.as_str())) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// WHATWG `hostname` getter: the host without the port. Borrows into the Url's
/// buffer; returns -1 (and writes an empty slice) when there is no host.
#[no_mangle]
pub unsafe extern "C" fn url_get_hostname(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) -> i32 {
    let url = unsafe { &*url };

    match url.host_str() {
        Some(h) => unsafe {
            *out_ptr = h.as_ptr();
            *out_len = h.len();
            0
        },
        None => unsafe {
            *out_len = 0;
            -1
        },
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_host(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) -> i32 {
    let url = unsafe { &*url };
    if url.host_str().is_none() {
        unsafe {
            *out_len = 0;
        }
        return -1;
    }

    let host = &url[url::Position::BeforeHost..url::Position::AfterPort];
    unsafe {
        *out_ptr = host.as_ptr();
        *out_len = host.len();
    }
    0
}

/// rust-url's `set_host` discards any trailing `:port`, so we split it off
/// ourselves (respecting IPv6 `[...]` literals) and apply the port separately.
#[no_mangle]
pub unsafe extern "C" fn url_set_host(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let input = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    // The WHATWG host setter parses in "host state", which stops at the first
    // '/', '?', '#' (and '\' for special schemes); the remainder is ignored
    // rather than making the whole value invalid.
    let special = matches!(
        url.scheme(),
        "http" | "https" | "ws" | "wss" | "ftp" | "file"
    );
    let end = input
        .find(|c| c == '/' || c == '?' || c == '#' || (special && c == '\\'))
        .unwrap_or(input.len());
    let input = &input[..end];

    // Find the port separator ':', but only outside an IPv6 [...] literal.
    let colon = if input.starts_with('[') {
        input
            .find(']')
            .and_then(|b| input[b..].find(':').map(|i| b + i))
    } else {
        input.find(':')
    };

    let Some(i) = colon else {
        // No port given: set the host only, leaving any existing port untouched.
        return if url.set_host(Some(input)).is_ok() {
            0
        } else {
            -1
        };
    };

    let (host, port_str) = (&input[..i], &input[i + 1..]);

    // A trailing colon with no digits ("host:") supplies an empty port, which
    // the WHATWG host setter ignores: set the host only, leaving any existing
    // port untouched (matches Chrome and Firefox).
    if port_str.is_empty() {
        return if url.set_host(Some(host)).is_ok() {
            0
        } else {
            -1
        };
    }

    // Validate the port up-front so we never apply the host and then fail.
    let new_port: u16 = match port_str.parse::<u16>() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    if url.set_host(Some(host)).is_err() {
        return -1;
    }
    // set_port only errors on cannot-be-a-base, already ruled out by set_host.
    let _ = url.set_port(Some(new_port));
    0
}

#[no_mangle]
pub unsafe extern "C" fn url_set_scheme(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    match url.set_scheme(slice) {
        Ok(()) => 0,
        Err(()) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_scheme(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) {
    let url = unsafe { &*url };
    let scheme = url.scheme();
    *out_ptr = scheme.as_ptr();
    *out_len = scheme.len();
}

#[no_mangle]
pub unsafe extern "C" fn url_set_path(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    url.set_path(slice);
    0
}

#[no_mangle]
pub unsafe extern "C" fn url_get_path(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) {
    let url = unsafe { &*url };
    let path = url.path();
    *out_ptr = path.as_ptr();
    *out_len = path.len();
}

#[no_mangle]
pub unsafe extern "C" fn url_set_query(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    url.set_query(Some(slice));
    0
}

#[no_mangle]
pub unsafe extern "C" fn url_set_query_to_null(url: *mut Url) {
    let url = unsafe { &mut *url };
    url.set_query(None);
}

#[no_mangle]
pub unsafe extern "C" fn url_get_query(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) -> i32 {
    let url = unsafe { &*url };
    match url.query() {
        Some(query) => {
            *out_ptr = query.as_ptr();
            *out_len = query.len();
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_set_fragment(url: *mut Url, ptr: *const c_uchar, len: usize) -> i32 {
    let url = unsafe { &mut *url };
    let slice = match str_from(ptr, len) {
        Some(s) => s,
        None => return -1,
    };

    url.set_fragment(Some(slice));
    0
}

#[no_mangle]
pub unsafe extern "C" fn url_set_fragment_to_null(url: *mut Url) {
    let url = unsafe { &mut *url };
    url.set_fragment(None);
}

#[no_mangle]
pub unsafe extern "C" fn url_get_fragment(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) -> i32 {
    let url = unsafe { &*url };
    match url.fragment() {
        Some(fragment) => {
            *out_ptr = fragment.as_ptr();
            *out_len = fragment.len();
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn url_get_href(
    url: *const Url,
    out_ptr: *mut *const c_uchar,
    out_len: *mut usize,
) {
    let url = unsafe { &*url };
    let href = url.as_str();
    *out_ptr = href.as_ptr();
    *out_len = href.len();
}

fn encode_query_ncr(encoding: &'static Encoding, s: &str) -> Cow<'static, [u8]> {
    // fast path: fully mappable
    let (out, _, had_errors) = encoding.encode(s);
    if !had_errors {
        return Cow::Owned(out.into_owned());
    }

    let mut encoder = encoding.new_encoder();
    let mut result = Vec::with_capacity(s.len() * 2);
    let mut input = s;
    loop {
        let needed = encoder
            .max_buffer_length_from_utf8_without_replacement(input.len())
            .unwrap();
        let start = result.len();
        result.resize(start + needed, 0);
        let (r, read, written) =
            encoder.encode_from_utf8_without_replacement(input, &mut result[start..], true);
        result.truncate(start + written);
        input = &input[read..];
        match r {
            EncoderResult::InputEmpty => break,
            EncoderResult::Unmappable(c) => {
                result.extend_from_slice(format!("%26%23{}%3B", c as u32).as_bytes());
            }
            // Output was sized with max_buffer_length, so it cannot run out.
            EncoderResult::OutputFull => unreachable!(),
        }
    }
    Cow::Owned(result)
}

#[no_mangle]
pub unsafe extern "C" fn url_resolve_with_encoding(
    base_ptr: *const c_uchar,
    base_len: usize,
    input_ptr: *const c_uchar,
    input_len: usize,
    enc_ptr: *const c_uchar,
    enc_len: usize,
    err: *mut i32,
) -> OwnedString {
    let base_slice = match str_from(base_ptr, base_len) {
        Some(s) => s,
        None => {
            *err = -1;
            return EMPTY_OWNED_STRING;
        }
    };
    // An empty base means the input must be an absolute URL.
    let base = if base_slice.is_empty() {
        None
    } else {
        match Url::parse(base_slice) {
            Ok(u) => Some(u),
            Err(_) => {
                *err = -1;
                return EMPTY_OWNED_STRING;
            }
        }
    };

    let slice = match str_from(input_ptr, input_len) {
        Some(s) => s,
        None => {
            *err = -1;
            return EMPTY_OWNED_STRING;
        }
    };

    let encoding_slice = match str_from(enc_ptr, enc_len) {
        Some(s) => s,
        None => {
            *err = -1;
            return EMPTY_OWNED_STRING;
        }
    };
    // Per the URL spec, queries use the document encoding's *output encoding*.
    let encoding = Encoding::for_label(encoding_slice.as_bytes())
        .map(|encoding| encoding.output_encoding())
        .filter(|&encoding| encoding != encoding_rs::UTF_8);

    let result = match encoding {
        Some(encoding) => Url::options()
            .base_url(base.as_ref())
            .encoding_override(Some(&move |s| encode_query_ncr(encoding, s)))
            .parse(slice),
        // Fallback to default.
        None => match &base {
            Some(base) => base.join(slice),
            None => Url::parse(slice),
        },
    };

    match result {
        Ok(url) => {
            *err = 0;
            let s = String::from(url); // Moves the serialization, no copy.
            let len = s.len();
            let ptr = Box::into_raw(s.into_bytes().into_boxed_slice()) as *mut c_uchar;
            OwnedString { ptr, len }
        }
        Err(_) => {
            *err = -1;
            EMPTY_OWNED_STRING
        }
    }
}

/// Similar to url_parse_with_base; returns a href instead.
#[no_mangle]
pub unsafe extern "C" fn url_resolve_without_encoding(
    base_ptr: *const c_uchar,
    base_len: usize,
    input_ptr: *const c_uchar,
    input_len: usize,
    err: *mut i32,
) -> OwnedString {
    let base_slice = match str_from(base_ptr, base_len) {
        Some(s) => s,
        None => {
            *err = -1;
            return EMPTY_OWNED_STRING;
        }
    };
    // An empty base means the input must be an absolute URL.
    let base = if base_slice.is_empty() {
        None
    } else {
        match Url::parse(base_slice) {
            Ok(u) => Some(u),
            Err(_) => {
                *err = -1;
                return EMPTY_OWNED_STRING;
            }
        }
    };

    let input = match str_from(input_ptr, input_len) {
        Some(s) => s,
        None => {
            *err = -1;
            return EMPTY_OWNED_STRING;
        }
    };

    let result = match &base {
        Some(base) => base.join(input),
        None => Url::parse(input),
    };
    match result {
        Ok(url) => {
            *err = 0;
            let s = String::from(url); // Moves the serialization, no copy.
            let len = s.len();
            let ptr = Box::into_raw(s.into_bytes().into_boxed_slice()) as *mut c_uchar;
            OwnedString { ptr, len }
        }
        Err(_) => {
            *err = -1;
            EMPTY_OWNED_STRING
        }
    }
}

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

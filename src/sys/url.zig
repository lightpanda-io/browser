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

//! Bindings for Servo's rust-url (https://github.com/servo/rust-url).
//! Check @src/html5ever/url.rs for Rust-side of the bindings.

const std = @import("std");
const mem = std.mem;

pub const Url = anyopaque;

pub const OwnedString = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub inline fn deinit(self: OwnedString) void {
        return free_owned_string(self);
    }

    pub inline fn slice(self: OwnedString) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// https://docs.rs/url/latest/url/enum.ParseError.html
pub const ParseError = enum(i32) {
    EmptyHost,
    IdnaError,
    InvalidPort,
    InvalidIpv4Address,
    InvalidIpv6Address,
    InvalidDomainCharacter,
    RelativeUrlWithoutBase,
    RelativeUrlWithCannotBeABaseBase,
    SetHostOnCannotBeABaseUrl,
    Overflow,
};

/// If return value is null, `err` indicates `ParseError`.
pub extern "c" fn url_parse(ptr: [*]const u8, len: usize, err: *i32) ?*Url;
/// If return value is null, `err` indicates `ParseError`.
/// More efficient than url_parse + url_join combination where possible.
pub extern "c" fn url_parse_with_base(base_ptr: [*]const u8, base_len: usize, ptr: [*]const u8, len: usize, err: *i32) ?*Url;
/// If return value is null, `err` indicates `ParseError`.
pub extern "c" fn url_join(base: *const Url, ptr: [*]const u8, len: usize, err: *i32) ?*Url;
pub extern "c" fn url_free(url: *Url) void;
pub extern "c" fn url_can_parse(ptr: [*]const u8, len: usize) bool;
pub extern "c" fn url_can_parse_with_base(base_ptr: [*]const u8, base_len: usize, ptr: [*]const u8, len: usize) bool;
pub extern "c" fn url_to_string(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) void;
pub extern "c" fn url_set_hostname(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_get_hostname(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) i32;
pub extern "c" fn url_set_host(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_get_host(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) i32;
/// This function allocates on Rust-side.
pub extern "c" fn url_get_origin(url: *const Url) OwnedString;
pub extern "c" fn free_owned_string(owned: OwnedString) void;
pub extern "c" fn url_set_port(url: *Url, port: u16) i32;
/// Sets the port to null.
pub extern "c" fn url_set_port_to_null(url: *Url) i32;
pub extern "c" fn url_set_username(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_get_username(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) void;
pub extern "c" fn url_set_password(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_get_password(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) i32;
pub extern "c" fn url_set_path(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_get_path(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) void;
pub extern "c" fn url_set_scheme(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_get_scheme(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) void;
pub extern "c" fn url_set_fragment(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_set_fragment_to_null(url: *Url) void;
pub extern "c" fn url_get_fragment(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) i32;
pub extern "c" fn url_set_query(url: *Url, ptr: [*]const u8, len: usize) i32;
pub extern "c" fn url_set_query_to_null(url: *Url) void;
pub extern "c" fn url_get_query(url: *const Url, out_ptr: *[*]const u8, out_len: *usize) i32;

extern "c" fn url_get_port(url: *const Url) i32;
pub inline fn urlGetPort(url: *const Url) ?u16 {
    const result = url_get_port(url);
    if (result < 0) return null;
    return @intCast(result);
}

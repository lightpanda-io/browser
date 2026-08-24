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

//! The ICU C API, from the copy bundled in V8's archive: bidi, Arabic
//! shaping and line breaking. Symbols carry ICU's major version, so this
//! moves with V8. The shared dev build of V8 only exports them from
//! lightpanda-io/zig-v8-fork#201 on; before that, link the static archive.

const version = "77";

fn sym(comptime name: []const u8, comptime T: type) *const T {
    return @extern(*const T, .{ .name = name ++ "_" ++ version });
}

pub const UBiDi = opaque {};
pub const UBreakIterator = opaque {};

pub const ubidi_open = sym("ubidi_open", fn () callconv(.c) ?*UBiDi);
pub const ubidi_close = sym("ubidi_close", fn (*UBiDi) callconv(.c) void);
pub const ubidi_setPara = sym("ubidi_setPara", fn (*UBiDi, [*]const u16, i32, u8, ?[*]u8, *c_int) callconv(.c) void);
pub const ubidi_getParaLevel = sym("ubidi_getParaLevel", fn (*const UBiDi) callconv(.c) u8);
pub const ubidi_getLevels = sym("ubidi_getLevels", fn (*UBiDi, *c_int) callconv(.c) ?[*]const u8);
pub const ubidi_reorderVisual = sym("ubidi_reorderVisual", fn ([*]const u8, i32, [*]i32) callconv(.c) void);
pub const u_shapeArabic = sym("u_shapeArabic", fn ([*]const u16, i32, [*]u16, i32, u32, *c_int) callconv(.c) i32);
pub const u_charMirror = sym("u_charMirror", fn (i32) callconv(.c) i32);
pub const ubrk_open = sym("ubrk_open", fn (c_int, ?[*:0]const u8, ?[*]const u16, i32, *c_int) callconv(.c) ?*UBreakIterator);
pub const ubrk_close = sym("ubrk_close", fn (*UBreakIterator) callconv(.c) void);
pub const ubrk_next = sym("ubrk_next", fn (*UBreakIterator) callconv(.c) i32);
pub const ubrk_getRuleStatus = sym("ubrk_getRuleStatus", fn (*UBreakIterator) callconv(.c) i32);

pub const UBIDI_DEFAULT_LTR: u8 = 0xfe;
pub const UBRK_LINE: c_int = 2;
pub const UBRK_DONE: i32 = -1;
pub const UBRK_LINE_HARD: i32 = 100;
pub const U_SHAPE_LETTERS_SHAPE_TASHKEEL_ISOLATED: u32 = 0x18;

/// UErrorCode: warnings are negative, U_ZERO_ERROR is 0, failures positive.
pub fn failed(err: c_int) bool {
    return err > 0;
}

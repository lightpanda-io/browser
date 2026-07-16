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

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";
pub const strike = "\x1b[9m";
// Color names follow isocline's (bbcode_colors.c): teal is the dark cyan
// pair of bright cyan, like maroon/red or olive/yellow.
pub const teal = "\x1b[36m";
pub const cyan = "\x1b[96m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const red = "\x1b[31m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const clear_eol = "\x1b[K";
pub const clear_line = "\x1b[2K";
// Kitty keyboard protocol; each push must pair with a pop.
pub const kitty_disambiguate = "\x1b[>1u";
pub const kitty_legacy = "\x1b[>0u";
pub const kitty_pop = "\x1b[<u";

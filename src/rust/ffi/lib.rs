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

//! The one staticlib Zig links. Domain crates define their own `extern "C"`
//! entry points; `extern crate` is what pulls an otherwise-unreferenced crate
//! into the archive (edition 2018+ drops unused `--extern` deps). Process-wide
//! concerns (the allocator) live here, not in a domain crate.

extern crate lightpanda_html5ever;
extern crate lightpanda_render;

#[cfg(feature = "memstats")]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

#[cfg(feature = "memstats")]
#[repr(C)]
pub struct Memory {
    pub resident: usize,
    pub allocated: usize,
}

#[cfg(feature = "memstats")]
#[no_mangle]
pub extern "C" fn html5ever_get_memory_usage() -> Memory {
    use tikv_jemalloc_ctl::{epoch, stats};

    // many statistics are cached and only updated when the epoch is advanced.
    let _ = epoch::advance();

    Memory {
        resident: stats::resident::read().unwrap_or(0),
        allocated: stats::allocated::read().unwrap_or(0),
    }
}

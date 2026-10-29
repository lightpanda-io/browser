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

// The graph renders one quantum at a time, pulled from the destination: a
// node pulls its inputs, then processes. Each node renders at most once per
// quantum (`AudioNode._rendered`).

const std = @import("std");

const js = @import("../../js/js.zig");

const Bus = @import("dsp/Bus.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const Allocator = std.mem.Allocator;

pub const Quantum = struct {
    // render count, starting at 1
    index: u64,
    // first sample frame
    frame: u64,
    sample_rate: f32,
    // the context's arena, for buses that grow
    allocator: Allocator,
    // for reading AudioBuffers' channel arrays
    local: *const js.Local,
    // sources that finished during this quantum, to get an `ended` event
    finished: *std.ArrayList(*AudioScheduledSourceNode),
    // one silent channel, for a node reached through a cycle or too deep
    silence: *const Bus,
    // nodes currently being pulled
    depth: u32 = 0,
};

// Deeper graphs render the excess as silence rather than overflow the stack.
pub const max_depth = 256;

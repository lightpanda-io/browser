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
// along with this program.  See <https://www.gnu.org/licenses/>.

//! `lightpanda agent --policy jev`: one structured decision per step instead
//! of a chat turn per step.
//!
//! A System One model (TypeSafe's Jev) picks an operation and its target from
//! an indexed table of what the page actually offers, in a single request. A
//! chat model is called only to write a field value for TYPE_TEXT.
//!
//! The policy is browser-use/jev-ultrafast's (MIT), kept as close to upstream
//! as this browser allows: the same operations, the same question shape,
//! the same instruction strings. It acts on the page it is given and never
//! navigates on its own.
//!
//! The one deliberate divergence is how the element table is bounded. Upstream
//! captures only elements whose centre lies inside a 1120x780 viewport, which
//! keeps its tables small for free. Lightpanda has no layout to ask, so labels
//! are deduplicated and capped instead.

pub const decider = @import("jev/decider.zig");
pub const prompts = @import("jev/prompts.zig");
pub const runner = @import("jev/runner.zig");
pub const table = @import("jev/table.zig");
pub const text = @import("jev/text.zig");

pub const default_max_actions = runner.default_max_actions;

pub const Config = struct {
    goal: []const u8,
    api_key: [:0]const u8,
    model: []const u8,
    base_url: []const u8,
    max_actions: u32 = default_max_actions,
};

test {
    // A `const` import alone does not pull a file's tests into the suite.
    _ = decider;
    _ = prompts;
    _ = runner;
    _ = table;
    _ = text;
}

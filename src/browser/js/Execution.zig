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

//! Execution context for worker-compatible APIs.
//!
//! This provides a common interface for APIs that work in both Window and Worker
//! contexts. Instead of taking `*Frame` (which is DOM-specific), these APIs take
//! `*Execution` which abstracts the common infrastructure.
//!
//! The bridge constructs an Execution on-the-fly from the current context,
//! whether it's a Page context or a Worker context.

const std = @import("std");
const lp = @import("lightpanda");

const Context = @import("Context.zig");
const Scheduler = @import("Scheduler.zig");
const Factory = @import("../Factory.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const Execution = @This();

context: *Context,

// Fields named to match Page for generic code (executor._factory works for both)
buf: []u8,
arena: Allocator,
call_arena: Allocator,
_factory: *Factory,
_scheduler: *Scheduler,

// Pointer to the url field (Page or WorkerGlobalScope) - allows access to current url even after navigation
url: *[:0]const u8,

// Pointer to the charset field of the global (Page or WorkerGlobalScope).
charset: *[]const u8,

// Returns the current base URL of the global scope.
pub fn base(self: *const Execution) [:0]const u8 {
    return self.context.global.base();
}

pub fn dupeString(self: *const Execution, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

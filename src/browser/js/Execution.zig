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
//! contexts. Instead of taking `*Page` (which is DOM-specific), these APIs take
//! `*Execution` which abstracts the common infrastructure.
//!
//! The bridge constructs an Execution on-the-fly from the current context,
//! whether it's a Page context or a Worker context.

const std = @import("std");
const Context = @import("Context.zig");
const Scheduler = @import("Scheduler.zig");
const Factory = @import("../Factory.zig");

const Allocator = std.mem.Allocator;

const Execution = @This();

context: *Context,

// Fields named to match Page for generic code (executor._factory works for both)
_factory: *Factory,
arena: Allocator,
call_arena: Allocator,
_scheduler: *Scheduler,
buf: []u8,

pub fn fromContext(ctx: *Context) Execution {
    const page = ctx.page;
    return .{
        .context = ctx,
        ._factory = page._factory,
        .arena = page.arena,
        .call_arena = ctx.call_arena,
        ._scheduler = &ctx.scheduler,
        .buf = &page.buf,
    };
}

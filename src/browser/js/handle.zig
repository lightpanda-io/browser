// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

//! References to a realm that are kept beyond the call that took them.
//!
//! A `Context` is destroyed when its frame navigates or its worker goes away,
//! while another realm can still hold, and call, the objects that were created
//! in it. The `Frame` struct is then re-initialized in place for the next
//! document, so a `*Frame` kept by such an object would name the wrong document,
//! and a `*Execution` would point into freed memory.

const Context = @import("Context.zig");
const Execution = @import("Execution.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const GlobalScope = @import("../global_scope.zig").GlobalScope;

/// What the handles of a realm point at. It belongs to the `Page`, which
/// outlives every object that can hold a handle.
pub const Anchor = struct {
    /// Cleared when `Context.deinit` starts.
    context: ?*Context,
    page: *Page,
    /// For an isolated world, the main world of its frame. Otherwise itself.
    main: *const Anchor,
};

/// For an object that would keep a `*Execution`.
pub const ExecutionHandle = struct {
    anchor: *const Anchor,

    pub fn get(self: ExecutionHandle) ?*Execution {
        const context = self.anchor.context orelse return null;
        return &context.execution;
    }

    pub fn js(self: ExecutionHandle) ?*Context {
        return self.anchor.context;
    }

    /// The `Frame` or `WorkerGlobalScope` of the realm. An isolated world can
    /// be destroyed before its frame.
    pub fn global(self: ExecutionHandle) ?GlobalScope {
        const context = self.anchor.main.context orelse return null;
        return context.global;
    }

    pub fn page(self: ExecutionHandle) *Page {
        return self.anchor.page;
    }
};

/// For an object that would keep a `*Frame`. It names the document the frame
/// had when the handle was taken, not whichever one the frame shows now.
pub const FrameHandle = struct {
    anchor: *const Anchor,

    pub fn get(self: FrameHandle) ?*Frame {
        const context = self.anchor.context orelse return null;
        return context.global.frame;
    }

    pub fn js(self: FrameHandle) ?*Context {
        return self.anchor.context;
    }

    pub fn page(self: FrameHandle) *Page {
        return self.anchor.page;
    }
};

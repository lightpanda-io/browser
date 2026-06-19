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

// Stand-in for the agent script `Runtime` on non-v8 builds. The real runtime
// (`Runtime.zig`) drives a bare V8 isolate through the raw `js.v8` C bindings,
// which only the V8 backend provides; the QuickJS backend has no equivalent.
// `lightpanda.zig` aliases `Runtime` to this when `build_config.v8` is false so
// `Agent` still compiles — `init` simply reports the feature as unavailable.
const std = @import("std");
const lp = @import("lightpanda");

const CDPNode = @import("../cdp/Node.zig");

const Runtime = @This();

pub const InitError = error{
    OutOfMemory,
    RuntimeInitFailed,
    TooManyContexts,
};

pub const RunError = error{
    OutOfMemory,
};

pub const ConsoleObserver = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) void,
};

console_observer: ?ConsoleObserver = null,

pub fn init(
    _: std.mem.Allocator,
    _: *lp.App,
    _: *lp.Session,
    _: *CDPNode.Registry,
) InitError!*Runtime {
    // The agent script runtime is only available on V8 builds.
    return error.RuntimeInitFailed;
}

pub fn deinit(_: *Runtime) void {}

pub fn terminate(_: *Runtime) void {}

pub fn cancelTerminate(_: *Runtime) void {}

pub fn runSource(_: *Runtime, _: []const u8, _: []const u8) RunError!?[]const u8 {
    return "agent script runtime is unavailable on this build";
}

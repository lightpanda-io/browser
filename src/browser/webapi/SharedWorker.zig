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

// The page-side handle for a shared worker. Unlike Worker, this owns nothing:
// the worker itself (SharedWorkerGlobalScope) is owned by the page that first
// created it and found through the Session's registry, keyed by
// (resolved url, name) — so every `new SharedWorker(url, name)` in the
// session, from any frame or page, talks to the same instance. All this
// handle keeps is its end of the connection's MessagePort pair.
//
// Divergence from the spec: the worker's lifetime is tied to its creating
// page, not to the set of connected clients. If the creator dies while
// another page is still connected, the worker dies and the surviving port
// goes quiet (entanglement is severed; nothing dangles).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");

const Worker = @import("Worker.zig");
const EventTarget = @import("EventTarget.zig");
const MessagePort = @import("MessagePort.zig");
const SharedWorkerGlobalScope = @import("SharedWorkerGlobalScope.zig");

const log = lp.log;

const SharedWorker = @This();

_proto: *EventTarget,
_port: *MessagePort,
_on_error: ?js.Function.Global = null,

const NameOrOpts = union(enum) {
    name: []const u8,
    options: Opts,

    const Opts = struct {
        name: []const u8 = "",
        type: Worker.WorkerType = .classic,
    };
};

pub fn init(url: []const u8, name_or_options: ?NameOrOpts, frame: *Frame) !*SharedWorker {
    const options: NameOrOpts.Opts = if (name_or_options) |noo| switch (noo) {
        .name => |n| .{ .name = n },
        .options => |o| o,
    } else .{};

    const resolved_url = try URL.resolve(frame.call_arena, frame.base(), url, .{ .encoding = frame.charset });

    const scope = blk: {
        const session = frame._session;
        // \x00 can appear in neither a URL nor a name
        const lookup_key = try std.fmt.allocPrint(frame.call_arena, "{s}\x00{s}", .{ resolved_url, options.name });
        if (session.shared_workers.get(lookup_key)) |existing| {
            break :blk existing;
        }

        const s = try SharedWorkerGlobalScope.init(frame, resolved_url, options.name, options.type);
        errdefer s.deinit();

        const page = frame._page;
        try page.shared_workers.append(page.frame_arena, s);
        errdefer _ = page.shared_workers.pop();

        try s.register(lookup_key);

        break :blk s;
    };

    const port = try scope.connect(&frame.js.execution);
    return frame._page.factory.eventTarget(SharedWorker{
        ._proto = undefined,
        ._port = port,
    });
}

pub fn asEventTarget(self: *SharedWorker) *EventTarget {
    return self._proto;
}

pub fn getPort(self: *const SharedWorker) *MessagePort {
    return self._port;
}

pub fn getOnError(self: *const SharedWorker) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *SharedWorker, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SharedWorker);

    pub const Meta = struct {
        pub const name = "SharedWorker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(SharedWorker.init, .{});

    pub const port = bridge.accessor(SharedWorker.getPort, null, .{});
    pub const onerror = bridge.accessor(SharedWorker.getOnError, SharedWorker.setOnError, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: SharedWorker" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("shared_worker", .{ .timeout_ms = 8000 });
}

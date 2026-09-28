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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");

const String = lp.String;

const ExtendableEvent = @This();

pub const Proto = Event;

_proto: *Event,

_pending: usize = 0, // Number of waitUntil promises that haven't settled yet.
_sealed: bool = false, // once sealed, _pending reaching 0 fires on_done
_on_done: ?Callback = null,

pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

const Options = Event.inheritOptions(ExtendableEvent, struct {});

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*ExtendableEvent {
    const arena = try page.getArena(.tiny, "ExtendableEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = opts_ orelse Options{};
    const event = try page.factory.event(arena, type_string, ExtendableEvent{
        ._proto = undefined,
    });

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*ExtendableEvent {
    const arena = try page.getArena(.tiny, "ExtendableEvent.trusted");
    errdefer arena.release();

    const opts = opts_ orelse Options{};
    const event = try page.factory.event(arena, typ, ExtendableEvent{
        ._proto = undefined,
    });

    Event.populatePrototypes(event, opts, true);
    return event;
}

pub fn deinit(self: *ExtendableEvent, page: *Page) void {
    self._proto.deinit(page);
}

pub fn releaseRef(self: *ExtendableEvent, page: *Page) void {
    self._proto._rc.release(self, page);
}

pub fn acquireRef(self: *ExtendableEvent) void {
    self._proto.acquireRef();
}

pub fn asEvent(self: *ExtendableEvent) *Event {
    return self._proto;
}

pub fn waitUntil(self: *ExtendableEvent, value: js.Value) !void {
    // Only a lifecycle event we're holding a ref on may register a promise: the
    // settle callback below keeps a raw pointer to us, and a page-constructed
    // event would be freed by GC before that promise settles.
    if (self._proto._is_trusted == false) {
        return error.InvalidStateError;
    }

    // Spec: no longer "active" once dispatch is over and nothing is pending.
    if (self._sealed and self._pending == 0) {
        return error.InvalidStateError;
    }

    if (value.isPromise() == false) {
        return;
    }

    self._pending += 1;

    const promise = value.toPromise();
    const local = promise.local;
    const settled = local.newCallback(onSettled, self);
    _ = promise.thenAndCatch(settled, settled) catch {
        self.settle();
    };
}

fn onSettled(self: *ExtendableEvent, _: ?js.Value) void {
    self.settle();
}

fn settle(self: *ExtendableEvent) void {
    if (self._pending == 0) {
        return;
    }
    self._pending -= 1;
    self.checkDone();
}
// Called by the dispatcher once its handlers have run.
pub fn seal(self: *ExtendableEvent, on_done: Callback) void {
    self._on_done = on_done;
    self._sealed = true;
    // From here on the event is done as soon as its outstanding promises are.
    self.checkDone();
}

fn checkDone(self: *ExtendableEvent) void {
    if (self._sealed == false or self._pending > 0) {
        return;
    }
    const on_done = self._on_done orelse return;
    self._on_done = null;
    on_done.func(on_done.ctx);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ExtendableEvent);

    pub const Meta = struct {
        pub const name = "ExtendableEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ExtendableEvent.init, .{});
    pub const waitUntil = bridge.function(ExtendableEvent.waitUntil, .{});
};

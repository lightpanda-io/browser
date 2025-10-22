const std = @import("std");

const js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;

const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventHandler = @import("../events/event.zig").EventHandler;

const parser = @import("../netsurf.zig");

pub const NavigationEventTarget = @This();

pub const prototype = *EventTarget;
// Extend libdom event target for pure zig struct.
base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .navigation },

oncurrententrychange_cbk: ?js.Function = null,

fn register(
    self: *NavigationEventTarget,
    alloc: std.mem.Allocator,
    typ: []const u8,
    listener: EventHandler.Listener,
) !?js.Function {
    const target = parser.toEventTarget(NavigationEventTarget, self);

    // The only time this can return null if the listener is already
    // registered. But before calling `register`, all of our functions
    // remove any existing listener, so it should be impossible to get null
    // from this function call.
    const eh = (try EventHandler.register(alloc, target, typ, listener, null)) orelse unreachable;
    return eh.callback;
}

fn unregister(self: *NavigationEventTarget, typ: []const u8, cbk_id: usize) !void {
    const et = parser.toEventTarget(NavigationEventTarget, self);
    // check if event target has already this listener
    const lst = try parser.eventTargetHasListener(et, typ, false, cbk_id);
    if (lst == null) {
        return;
    }

    // remove listener
    try parser.eventTargetRemoveEventListener(et, typ, lst.?, false);
}

pub fn get_oncurrententrychange(self: *NavigationEventTarget) ?js.Function {
    return self.oncurrententrychange_cbk;
}

pub fn set_oncurrententrychange(self: *NavigationEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
    if (self.oncurrententrychange_cbk) |cbk| try self.unregister("currententrychange", cbk.id);
    if (listener) |listen| {
        self.oncurrententrychange_cbk = try self.register(page.arena, "currententrychange", listen);
    } else {
        self.oncurrententrychange_cbk = null;
    }
}

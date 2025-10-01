// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const std = @import("std");
const js = @import("../js/js.zig");

const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventHandler = @import("../events/event.zig").EventHandler;

const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

pub const XMLHttpRequestEventTarget = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .xhr },

    onloadstart_cbk: ?js.Function = null,
    onprogress_cbk: ?js.Function = null,
    onabort_cbk: ?js.Function = null,
    onload_cbk: ?js.Function = null,
    ontimeout_cbk: ?js.Function = null,
    onloadend_cbk: ?js.Function = null,
    onreadystatechange_cbk: ?js.Function = null,

    fn register(
        self: *XMLHttpRequestEventTarget,
        alloc: std.mem.Allocator,
        typ: []const u8,
        listener: EventHandler.Listener,
    ) !?js.Function {
        const target = @as(*parser.EventTarget, @ptrCast(self));

        // The only time this can return null if the listener is already
        // registered. But before calling `register`, all of our functions
        // remove any existing listener, so it should be impossible to get null
        // from this function call.
        const eh = (try EventHandler.register(alloc, target, typ, listener, null)) orelse unreachable;
        return eh.callback;
    }

    fn unregister(self: *XMLHttpRequestEventTarget, typ: []const u8, cbk_id: usize) !void {
        const et = @as(*parser.EventTarget, @ptrCast(self));
        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(et, typ, false, cbk_id);
        if (lst == null) {
            return;
        }

        // remove listener
        try parser.eventTargetRemoveEventListener(et, typ, lst.?, false);
    }

    pub fn get_onloadstart(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.onloadstart_cbk;
    }
    pub fn get_onprogress(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.onprogress_cbk;
    }
    pub fn get_onabort(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.onabort_cbk;
    }
    pub fn get_onload(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.onload_cbk;
    }
    pub fn get_ontimeout(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.ontimeout_cbk;
    }
    pub fn get_onloadend(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.onloadend_cbk;
    }
    pub fn get_onreadystatechange(self: *XMLHttpRequestEventTarget) ?js.Function {
        return self.onreadystatechange_cbk;
    }

    pub fn set_onloadstart(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.onloadstart_cbk) |cbk| try self.unregister("loadstart", cbk.id);
        if (listener) |listen| {
            self.onloadstart_cbk = try self.register(page.arena, "loadstart", listen);
        }
    }
    pub fn set_onprogress(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.onprogress_cbk) |cbk| try self.unregister("progress", cbk.id);
        if (listener) |listen| {
            self.onprogress_cbk = try self.register(page.arena, "progress", listen);
        }
    }
    pub fn set_onabort(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.onabort_cbk) |cbk| try self.unregister("abort", cbk.id);
        if (listener) |listen| {
            self.onabort_cbk = try self.register(page.arena, "abort", listen);
        }
    }
    pub fn set_onload(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.onload_cbk) |cbk| try self.unregister("load", cbk.id);
        if (listener) |listen| {
            self.onload_cbk = try self.register(page.arena, "load", listen);
        }
    }
    pub fn set_ontimeout(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.ontimeout_cbk) |cbk| try self.unregister("timeout", cbk.id);

        if (listener) |listen| {
            self.ontimeout_cbk = try self.register(page.arena, "timeout", listen);
        }
    }
    pub fn set_onloadend(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.onloadend_cbk) |cbk| try self.unregister("loadend", cbk.id);

        if (listener) |listen| {
            self.onloadend_cbk = try self.register(page.arena, "loadend", listen);
        }
    }
    pub fn set_onreadystatechange(self: *XMLHttpRequestEventTarget, listener: ?EventHandler.Listener, page: *Page) !void {
        if (self.onreadystatechange_cbk) |cbk| try self.unregister("readystatechange", cbk.id);

        if (listener) |listen| {
            self.onreadystatechange_cbk = try self.register(page.arena, "readystatechange", listen);
        }
    }
};

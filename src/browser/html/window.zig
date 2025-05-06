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

const parser = @import("../netsurf.zig");
const Callback = @import("../env.zig").Callback;
const SessionState = @import("../env.zig").SessionState;
const Loop = @import("../../runtime/loop.zig").Loop;

const Navigator = @import("navigator.zig").Navigator;
const History = @import("history.zig").History;
const Location = @import("location.zig").Location;
const Crypto = @import("../crypto/crypto.zig").Crypto;
const Console = @import("../console/console.zig").Console;
const EventTarget = @import("../dom/event_target.zig").EventTarget;

const storage = @import("../storage/storage.zig");

const log = std.log.scoped(.window);

// https://dom.spec.whatwg.org/#interface-window-extensions
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#window
pub const Window = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{},

    document: ?*parser.DocumentHTML = null,
    target: []const u8 = "",
    history: History = .{},
    location: Location = .{},
    storage_shelf: ?*storage.Shelf = null,

    // counter for having unique timer ids
    timer_id: u31 = 0,
    timers: std.AutoHashMapUnmanaged(u32, *TimerCallback) = .{},

    crypto: Crypto = .{},
    console: Console = .{},
    navigator: Navigator = .{},

    pub fn create(target: ?[]const u8, navigator: ?Navigator) Window {
        return .{
            .target = target orelse "",
            .navigator = navigator orelse .{},
        };
    }

    pub fn replaceLocation(self: *Window, loc: Location) !void {
        self.location = loc;
        if (self.document) |doc| {
            try parser.documentHTMLSetLocation(Location, doc, &self.location);
        }
    }

    pub fn replaceDocument(self: *Window, doc: *parser.DocumentHTML) !void {
        self.document = doc;
        try parser.documentHTMLSetLocation(Location, doc, &self.location);
    }

    pub fn setStorageShelf(self: *Window, shelf: *storage.Shelf) void {
        self.storage_shelf = shelf;
    }

    pub fn get_window(self: *Window) *Window {
        return self;
    }

    pub fn get_navigator(self: *Window) *Navigator {
        return &self.navigator;
    }

    pub fn get_location(self: *Window) *Location {
        return &self.location;
    }

    pub fn get_console(self: *Window) *Console {
        return &self.console;
    }

    pub fn get_crypto(self: *Window) *Crypto {
        return &self.crypto;
    }

    pub fn get_self(self: *Window) *Window {
        return self;
    }

    pub fn get_parent(self: *Window) *Window {
        return self;
    }

    pub fn get_document(self: *Window) ?*parser.DocumentHTML {
        return self.document;
    }

    pub fn get_history(self: *Window) *History {
        return &self.history;
    }

    pub fn get_name(self: *Window) []const u8 {
        return self.target;
    }

    pub fn get_localStorage(self: *Window) !*storage.Bottle {
        if (self.storage_shelf == null) return parser.DOMError.NotSupported;
        return &self.storage_shelf.?.bucket.local;
    }

    pub fn get_sessionStorage(self: *Window) !*storage.Bottle {
        if (self.storage_shelf == null) return parser.DOMError.NotSupported;
        return &self.storage_shelf.?.bucket.session;
    }

    // TODO handle callback arguments.
    pub fn _setTimeout(self: *Window, cbk: Callback, delay: ?u32, state: *SessionState) !u32 {
        return self.createTimeout(cbk, delay, state, false);
    }

    // TODO handle callback arguments.
    pub fn _setInterval(self: *Window, cbk: Callback, delay: ?u32, state: *SessionState) !u32 {
        return self.createTimeout(cbk, delay, state, true);
    }

    pub fn _clearTimeout(self: *Window, id: u32, state: *SessionState) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        try state.loop.cancel(kv.value.loop_id);
    }

    pub fn _clearInterval(self: *Window, id: u32, state: *SessionState) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        try state.loop.cancel(kv.value.loop_id);
    }

    pub fn createTimeout(self: *Window, cbk: Callback, delay_: ?u32, state: *SessionState, comptime repeat: bool) !u32 {
        if (self.timers.count() > 512) {
            return error.TooManyTimeout;
        }
        const timer_id = self.timer_id +% 1;
        self.timer_id = timer_id;

        const arena = state.arena;

        const gop = try self.timers.getOrPut(arena, timer_id);
        if (gop.found_existing) {
            // this can only happen if we've created 2^31 timeouts.
            return error.TooManyTimeout;
        }
        errdefer _ = self.timers.remove(timer_id);

        const delay: u63 = (delay_ orelse 0) * std.time.ns_per_ms;
        const callback = try arena.create(TimerCallback);

        callback.* = .{
            .cbk = cbk,
            .loop_id = 0, // we're going to set this to a real value shortly
            .window = self,
            .timer_id = timer_id,
            .node = .{ .func = TimerCallback.run },
            .repeat = if (repeat) delay else null,
        };
        callback.loop_id = try state.loop.timeout(delay, &callback.node);

        gop.value_ptr.* = callback;
        return timer_id;
    }
};

const TimerCallback = struct {
    // the internal loop id, need it when cancelling
    loop_id: usize,

    // the id of our timer (windows.timers key)
    timer_id: u31,

    // The JavaScript callback to execute
    cbk: Callback,

    // This is the internal data that the event loop tracks. We'll get this
    // back in run and, from it, can get our TimerCallback instance
    node: Loop.CallbackNode = undefined,

    // if the event should be repeated
    repeat: ?u63 = null,

    window: *Window,

    fn run(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *TimerCallback = @fieldParentPtr("node", node);

        var result: Callback.Result = undefined;
        self.cbk.tryCall(.{}, &result) catch {
            log.err("timeout callback error: {s}", .{result.exception});
            log.debug("stack:\n{s}", .{result.stack orelse "???"});
        };

        if (self.repeat) |r| {
            // setInterval
            repeat_delay.* = r;
            return;
        }

        // setTimeout
        _ = self.window.timers.remove(self.timer_id);
    }
};

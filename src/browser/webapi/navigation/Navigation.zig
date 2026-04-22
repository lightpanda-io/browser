// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");
const URL = @import("../URL.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const log = lp.log;

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

const NavigationKind = @import("root.zig").NavigationKind;
const NavigationActivation = @import("NavigationActivation.zig");
const NavigationTransition = @import("root.zig").NavigationTransition;
const NavigationState = @import("root.zig").NavigationState;

const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");
const NavigationCurrentEntryChangeEvent = @import("../event/NavigationCurrentEntryChangeEvent.zig");

_proto: *EventTarget,
_on_currententrychange: ?js.Function.Global = null,

_current_navigation_kind: ?NavigationKind = null,

_index: usize = 0,
// Need to be stable pointers, because Events can reference entries.
_entries: std.ArrayList(*NavigationHistoryEntry) = .empty,
_next_entry_id: usize = 0,
_activation: ?NavigationActivation = null,

fn asEventTarget(self: *Navigation) *EventTarget {
    return self._proto;
}

pub fn onRemoveFrame(self: *Navigation) void {
    self._proto = undefined;
}

pub fn onNewFrame(self: *Navigation, frame: *Frame) !void {
    self._proto = try frame._factory.standaloneEventTarget(self);
}

pub fn getActivation(self: *const Navigation) ?NavigationActivation {
    return self._activation;
}

pub fn getCanGoBack(self: *const Navigation) bool {
    return self._index > 0;
}

pub fn getCanGoForward(self: *const Navigation) bool {
    return self._entries.items.len > self._index + 1;
}

pub fn getCurrentEntryOrNull(self: *Navigation) ?*NavigationHistoryEntry {
    if (self._entries.items.len > self._index) {
        return self._entries.items[self._index];
    } else return null;
}

pub fn getCurrentEntry(self: *Navigation) *NavigationHistoryEntry {
    // This should never fail. An entry should always be created before
    // we run the scripts on the frame we are loading.
    const len = self._entries.items.len;
    lp.assert(len > 0, "Navigation.getCurrentEntry", .{ .len = len });

    return self.getCurrentEntryOrNull().?;
}

pub fn getTransition(_: *const Navigation) ?NavigationTransition {
    // For now, all transitions are just considered complete.
    return null;
}

const NavigationReturn = struct {
    committed: js.Promise.Global,
    finished: js.Promise.Global,
};

pub fn back(self: *Navigation, frame: *Frame) !NavigationReturn {
    if (!self.getCanGoBack()) {
        return error.InvalidStateError;
    }

    const new_index = self._index - 1;
    const next_entry = self._entries.items[new_index];

    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, frame);
}

pub fn entries(self: *const Navigation) []*NavigationHistoryEntry {
    return self._entries.items;
}

pub fn forward(self: *Navigation, frame: *Frame) !NavigationReturn {
    if (!self.getCanGoForward()) {
        return error.InvalidStateError;
    }

    const new_index = self._index + 1;
    const next_entry = self._entries.items[new_index];

    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, frame);
}

pub fn updateEntries(
    self: *Navigation,
    url: [:0]const u8,
    kind: NavigationKind,
    frame: *Frame,
    should_dispatch: bool,
) !void {
    switch (kind) {
        .replace => |state| {
            _ = try self.replaceEntry(url, .{ .source = .navigation, .value = state }, frame, should_dispatch);
        },
        .push => |state| {
            _ = try self.pushEntry(url, .{ .source = .navigation, .value = state }, frame, should_dispatch);
        },
        .traverse => |index| {
            self._index = index;
        },
        .reload => {},
    }
}

// This is for after true navigation processing, where we need to ensure that our entries are up to date.
//
// This is only really safe to run in the `frameDoneCallback`
// where we can guarantee that the URL and NavigationKind are correct.
pub fn commitNavigation(self: *Navigation, frame: *Frame) !void {
    const url = frame.url;

    const kind: NavigationKind = self._current_navigation_kind orelse .{ .push = null };
    defer self._current_navigation_kind = null;

    const from_entry = self.getCurrentEntryOrNull();
    try self.updateEntries(url, kind, frame, false);

    self._activation = NavigationActivation{
        ._from = from_entry,
        ._entry = self.getCurrentEntry(),
        ._type = kind.toNavigationType(),
    };
}

/// Pushes an entry into the Navigation stack WITHOUT actually navigating to it.
/// For that, use `navigate`.
pub fn pushEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    frame: *Frame,
    should_dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = frame._session.arena;
    const url = try arena.dupeZ(u8, _url);

    // truncates our history here.
    if (self._entries.items.len > self._index + 1) {
        self._entries.shrinkRetainingCapacity(self._index + 1);
    }

    const index = self._entries.items.len;

    const id = self._next_entry_id;
    self._next_entry_id += 1;

    const id_str = try std.fmt.allocPrint(arena, "{d}", .{id});

    const entry = try arena.create(NavigationHistoryEntry);
    entry.* = NavigationHistoryEntry{
        ._id = id_str,
        ._key = id_str,
        ._url = url,
        ._state = state,
    };

    // we don't always have a current entry...
    const previous = if (self._entries.items.len > 0) self.getCurrentEntry() else null;
    try self._entries.append(arena, entry);
    self._index = index;

    if (previous == null or should_dispatch == false) {
        return entry;
    }

    if (self._on_currententrychange) |cec| {
        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous.?, .navigationType = @tagName(.push) },
            frame,
        )).asEvent();
        try self.dispatch(cec, event, frame);
    }

    return entry;
}

pub fn replaceEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    frame: *Frame,
    should_dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = frame._session.arena;
    const url = try arena.dupeZ(u8, _url);

    const previous = self.getCurrentEntry();

    const id = self._next_entry_id;
    self._next_entry_id += 1;
    const id_str = try std.fmt.allocPrint(arena, "{d}", .{id});

    const entry = try arena.create(NavigationHistoryEntry);
    entry.* = NavigationHistoryEntry{
        ._id = id_str,
        ._key = previous._key,
        ._url = url,
        ._state = state,
    };

    self._entries.items[self._index] = entry;

    if (should_dispatch == false) {
        return entry;
    }

    if (self._on_currententrychange) |cec| {
        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = @tagName(.replace) },
            frame,
        )).asEvent();
        try self.dispatch(cec, event, frame);
    }

    return entry;
}

const NavigateOptions = struct {
    state: ?js.Value = null,
    info: ?js.Value = null,
    history: ?[]const u8 = null,
};

pub fn navigateInner(
    self: *Navigation,
    _url: ?[:0]const u8,
    kind: NavigationKind,
    frame: *Frame,
) !NavigationReturn {
    const arena = frame._session.arena;
    const url = _url orelse return error.MissingURL;

    // https://github.com/WICG/navigation-api/issues/95
    //
    // These will only settle on same-origin navigation (mostly intended for SPAs).
    // It is fine (and expected) for these to not settle on cross-origin requests :)
    const local = frame.js.local.?;
    const committed = local.createPromiseResolver();
    const finished = local.createPromiseResolver();

    var new_url = try URL.resolve(arena, frame.url, url, .{});
    const is_same_document = URL.eqlDocument(new_url, frame.url);

    // In case of navigation to the same document, we force an url duplication.
    // Keeping the same url generates a crash during WPT test navigate-history-push-same-url.html.
    // When building a script's src, script's base and frame url overlap.
    if (is_same_document) {
        new_url = try arena.dupeZ(u8, new_url);
    }

    const previous = self.getCurrentEntry();

    switch (kind) {
        .push => |state| {
            if (is_same_document) {
                frame.url = new_url;

                committed.resolve("navigation push", {});
                // todo: Fire navigate event
                finished.resolve("navigation push", {});

                _ = try self.pushEntry(url, .{ .source = .navigation, .value = state }, frame, true);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .replace => |state| {
            if (is_same_document) {
                frame.url = new_url;

                committed.resolve("navigation replace", {});
                // todo: Fire navigate event
                finished.resolve("navigation replace", {});

                _ = try self.replaceEntry(url, .{ .source = .navigation, .value = state }, frame, true);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .traverse => |index| {
            self._index = index;

            if (is_same_document) {
                frame.url = new_url;

                committed.resolve("navigation traverse", {});
                // todo: Fire navigate event
                finished.resolve("navigation traverse", {});
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .reload => {
            try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
        },
    }

    if (self._on_currententrychange) |cec| {
        // If we haven't navigated off, let us fire off an a currententrychange.
        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = @tagName(kind) },
            frame,
        )).asEvent();
        try self.dispatch(cec, event, frame);
    }

    _ = try committed.persist();
    _ = try finished.persist();
    return .{
        .committed = try committed.promise().persist(),
        .finished = try finished.promise().persist(),
    };
}

pub fn navigate(self: *Navigation, _url: [:0]const u8, _opts: ?NavigateOptions, frame: *Frame) !NavigationReturn {
    const arena = frame._session.arena;
    const opts = _opts orelse NavigateOptions{};
    const json = if (opts.state) |state| state.toJson(arena) catch return error.DataClone else null;

    const kind: NavigationKind = if (opts.history) |history|
        if (std.mem.eql(u8, "replace", history)) .{ .replace = json } else .{ .push = json }
    else
        .{ .push = json };

    return try self.navigateInner(_url, kind, frame);
}

pub const ReloadOptions = struct {
    state: ?js.Value = null,
    info: ?js.Value = null,
};

pub fn reload(self: *Navigation, _opts: ?ReloadOptions, frame: *Frame) !NavigationReturn {
    const arena = frame._session.arena;

    const opts = _opts orelse ReloadOptions{};
    const entry = self.getCurrentEntry();
    if (opts.state) |state| {
        const previous = entry;
        entry._state = .{ .source = .navigation, .value = state.toJson(arena) catch return error.DataClone };

        const event = try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = @tagName(.reload) },
            frame,
        );
        try self.dispatch(.{ .currententrychange = event }, frame);
    }

    return self.navigateInner(entry._url, .reload, frame);
}

pub const TraverseToOptions = struct {
    info: ?js.Value = null,
};

pub fn traverseTo(self: *Navigation, key: []const u8, _opts: ?TraverseToOptions, frame: *Frame) !NavigationReturn {
    if (_opts != null) {
        log.warn(.not_implemented, "Navigation.traverseTo", .{ .has_options = true });
    }

    for (self._entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, key, entry._key)) {
            return try self.navigateInner(entry._url, .{ .traverse = i }, frame);
        }
    }

    return error.InvalidStateError;
}

pub const UpdateCurrentEntryOptions = struct {
    state: js.Value,
};

pub fn updateCurrentEntry(self: *Navigation, options: UpdateCurrentEntryOptions, frame: *Frame) !void {
    const arena = frame._session.arena;

    const previous = self.getCurrentEntry();
    self.getCurrentEntry()._state = .{
        .source = .navigation,
        .value = options.state.toJson(arena) catch return error.DataClone,
    };

    if (self._on_currententrychange) |cec| {
        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = null },
            frame,
        )).asEvent();
        try self.dispatch(cec, event, frame);
    }
}

pub fn dispatch(self: *Navigation, func: js.Function.Global, event: *Event, frame: *Frame) !void {
    return frame._event_manager.dispatchDirect(
        self.asEventTarget(),
        event,
        func,
        .{ .context = "Navigation" },
    );
}

fn getOnCurrentEntryChange(self: *Navigation) ?js.Function.Global {
    return self._on_currententrychange;
}

pub fn setOnCurrentEntryChange(self: *Navigation, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_currententrychange = try listen.persistWithThis(self);
    } else {
        self._on_currententrychange = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigation);

    pub const Meta = struct {
        pub const name = "Navigation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const activation = bridge.accessor(Navigation.getActivation, null, .{});
    pub const canGoBack = bridge.accessor(Navigation.getCanGoBack, null, .{});
    pub const canGoForward = bridge.accessor(Navigation.getCanGoForward, null, .{});
    pub const currentEntry = bridge.accessor(Navigation.getCurrentEntry, null, .{});
    pub const transition = bridge.accessor(Navigation.getTransition, null, .{});
    pub const back = bridge.function(Navigation.back, .{ .dom_exception = true });
    pub const entries = bridge.function(Navigation.entries, .{});
    pub const forward = bridge.function(Navigation.forward, .{ .dom_exception = true });
    pub const navigate = bridge.function(Navigation.navigate, .{ .dom_exception = true });
    pub const traverseTo = bridge.function(Navigation.traverseTo, .{ .dom_exception = true });
    pub const updateCurrentEntry = bridge.function(Navigation.updateCurrentEntry, .{ .dom_exception = true });

    pub const oncurrententrychange = bridge.accessor(
        Navigation.getOnCurrentEntryChange,
        Navigation.setOnCurrentEntryChange,
        .{},
    );
};

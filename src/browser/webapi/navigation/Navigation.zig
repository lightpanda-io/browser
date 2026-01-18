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
const log = @import("../../../log.zig");
const URL = @import("../URL.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const EventTarget = @import("../EventTarget.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

const NavigationKind = @import("root.zig").NavigationKind;
const NavigationActivation = @import("NavigationActivation.zig");
const NavigationTransition = @import("root.zig").NavigationTransition;
const NavigationState = @import("root.zig").NavigationState;

const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");
const NavigationCurrentEntryChangeEvent = @import("../event/NavigationCurrentEntryChangeEvent.zig");
const NavigationEventTarget = @import("NavigationEventTarget.zig");

_proto: *NavigationEventTarget = undefined,
_current_navigation_kind: ?NavigationKind = null,

_index: usize = 0,
// Need to be stable pointers, because Events can reference entries.
_entries: std.ArrayList(*NavigationHistoryEntry) = .empty,
_next_entry_id: usize = 0,
_activation: ?NavigationActivation = null,

fn asEventTarget(self: *Navigation) *EventTarget {
    return self._proto.asEventTarget();
}

pub fn onRemovePage(self: *Navigation) void {
    self._proto = undefined;
}

pub fn onNewPage(self: *Navigation, page: *Page) !void {
    self._proto = try page._factory.eventTarget(
        NavigationEventTarget{ ._proto = undefined },
    );
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
    // we run the scripts on the page we are loading.
    std.debug.assert(self._entries.items.len > 0);

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

pub fn back(self: *Navigation, page: *Page) !NavigationReturn {
    if (!self.getCanGoBack()) {
        return error.InvalidStateError;
    }

    const new_index = self._index - 1;
    const next_entry = self._entries.items[new_index];

    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, page);
}

pub fn entries(self: *const Navigation) []*NavigationHistoryEntry {
    return self._entries.items;
}

pub fn forward(self: *Navigation, page: *Page) !NavigationReturn {
    if (!self.getCanGoForward()) {
        return error.InvalidStateError;
    }

    const new_index = self._index + 1;
    const next_entry = self._entries.items[new_index];

    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, page);
}

pub fn updateEntries(self: *Navigation, url: [:0]const u8, kind: NavigationKind, page: *Page, dispatch: bool) !void {
    switch (kind) {
        .replace => |state| {
            _ = try self.replaceEntry(url, .{ .source = .navigation, .value = state }, page, dispatch);
        },
        .push => |state| {
            _ = try self.pushEntry(url, .{ .source = .navigation, .value = state }, page, dispatch);
        },
        .traverse => |index| {
            self._index = index;
        },
        .reload => {},
    }
}

// This is for after true navigation processing, where we need to ensure that our entries are up to date.
//
// This is only really safe to run in the `pageDoneCallback`
// where we can guarantee that the URL and NavigationKind are correct.
pub fn commitNavigation(self: *Navigation, page: *Page) !void {
    const url = page.url;

    const kind: NavigationKind = self._current_navigation_kind orelse .{ .push = null };
    defer self._current_navigation_kind = null;

    const from_entry = self.getCurrentEntryOrNull();
    try self.updateEntries(url, kind, page, false);

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
    page: *Page,
    dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = page._session.arena;
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

    if (previous) |prev| {
        if (dispatch) {
            const event = try NavigationCurrentEntryChangeEvent.initTrusted(
                "currententrychange",
                .{ .from = prev, .navigationType = @tagName(.push) },
                page,
            );
            try self._proto.dispatch(.{ .currententrychange = event }, page);
        }
    }

    return entry;
}

pub fn replaceEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    page: *Page,
    dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = page._session.arena;
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

    if (dispatch) {
        const event = try NavigationCurrentEntryChangeEvent.initTrusted(
            "currententrychange",
            .{ .from = previous, .navigationType = @tagName(.replace) },
            page,
        );
        try self._proto.dispatch(.{ .currententrychange = event }, page);
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
    page: *Page,
) !NavigationReturn {
    const arena = page._session.arena;
    const url = _url orelse return error.MissingURL;

    // https://github.com/WICG/navigation-api/issues/95
    //
    // These will only settle on same-origin navigation (mostly intended for SPAs).
    // It is fine (and expected) for these to not settle on cross-origin requests :)
    const committed = try page.js.createPromiseResolver().persist();
    const finished = try page.js.createPromiseResolver().persist();

    const new_url = try URL.resolve(arena, page.url, url, .{});
    const is_same_document = URL.eqlDocument(new_url, page.url);

    const previous = self.getCurrentEntry();

    switch (kind) {
        .push => |state| {
            if (is_same_document) {
                page.url = new_url;

                committed.local().resolve("navigation push", {});
                // todo: Fire navigate event
                finished.local().resolve("navigation push", {});

                _ = try self.pushEntry(url, .{ .source = .navigation, .value = state }, page, true);
            } else {
                try page.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .script);
            }
        },
        .replace => |state| {
            if (is_same_document) {
                page.url = new_url;

                committed.local().resolve("navigation replace", {});
                // todo: Fire navigate event
                finished.local().resolve("navigation replace", {});

                _ = try self.replaceEntry(url, .{ .source = .navigation, .value = state }, page, true);
            } else {
                try page.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .script);
            }
        },
        .traverse => |index| {
            self._index = index;

            if (is_same_document) {
                page.url = new_url;

                committed.local().resolve("navigation traverse", {});
                // todo: Fire navigate event
                finished.local().resolve("navigation traverse", {});
            } else {
                try page.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .script);
            }
        },
        .reload => {
            try page.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .script);
        },
    }

    // If we haven't navigated off, let us fire off an a currententrychange.
    const event = try NavigationCurrentEntryChangeEvent.initTrusted(
        "currententrychange",
        .{ .from = previous, .navigationType = @tagName(kind) },
        page,
    );
    try self._proto.dispatch(.{ .currententrychange = event }, page);

    return .{
        .committed = try committed.local().promise().persist(),
        .finished = try finished.local().promise().persist(),
    };
}

pub fn navigate(self: *Navigation, _url: [:0]const u8, _opts: ?NavigateOptions, page: *Page) !NavigationReturn {
    const arena = page._session.arena;
    const opts = _opts orelse NavigateOptions{};
    const json = if (opts.state) |state| state.toJson(arena) catch return error.DataClone else null;

    const kind: NavigationKind = if (opts.history) |history|
        if (std.mem.eql(u8, "replace", history)) .{ .replace = json } else .{ .push = json }
    else
        .{ .push = json };

    return try self.navigateInner(_url, kind, page);
}

pub const ReloadOptions = struct {
    state: ?js.Value = null,
    info: ?js.Value = null,
};

pub fn reload(self: *Navigation, _opts: ?ReloadOptions, page: *Page) !NavigationReturn {
    const arena = page._session.arena;

    const opts = _opts orelse ReloadOptions{};
    const entry = self.getCurrentEntry();
    if (opts.state) |state| {
        const previous = entry;
        entry._state = .{ .source = .navigation, .value = state.toJson(arena) catch return error.DataClone };

        const event = try NavigationCurrentEntryChangeEvent.initTrusted(
            "currententrychange",
            .{ .from = previous, .navigationType = @tagName(.reload) },
            page,
        );
        try self._proto.dispatch(.{ .currententrychange = event }, page);
    }

    return self.navigateInner(entry._url, .reload, page);
}

pub const TraverseToOptions = struct {
    info: ?js.Value = null,
};

pub fn traverseTo(self: *Navigation, key: []const u8, _opts: ?TraverseToOptions, page: *Page) !NavigationReturn {
    if (_opts != null) {
        log.warn(.not_implemented, "Navigation.traverseTo", .{ .has_options = true });
    }

    for (self._entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, key, entry._key)) {
            return try self.navigateInner(entry._url, .{ .traverse = i }, page);
        }
    }

    return error.InvalidStateError;
}

pub const UpdateCurrentEntryOptions = struct {
    state: js.Value,
};

pub fn updateCurrentEntry(self: *Navigation, options: UpdateCurrentEntryOptions, page: *Page) !void {
    const arena = page._session.arena;

    const previous = self.getCurrentEntry();
    self.getCurrentEntry()._state = .{
        .source = .navigation,
        .value = options.state.toJson(arena) catch return error.DataClone,
    };

    const event = try NavigationCurrentEntryChangeEvent.initTrusted(
        "currententrychange",
        .{ .from = previous, .navigationType = null },
        page,
    );
    try self._proto.dispatch(.{ .currententrychange = event }, page);
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
    pub const back = bridge.function(Navigation.back, .{});
    pub const entries = bridge.function(Navigation.entries, .{});
    pub const forward = bridge.function(Navigation.forward, .{});
    pub const navigate = bridge.function(Navigation.navigate, .{});
    pub const traverseTo = bridge.function(Navigation.traverseTo, .{});
    pub const updateCurrentEntry = bridge.function(Navigation.updateCurrentEntry, .{});
};

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
const log = @import("../../log.zig");
const URL = @import("../../url.zig").URL;

const js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;

const DirectEventHandler = @import("../events/event.zig").DirectEventHandler;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventHandler = @import("../events/event.zig").EventHandler;

const parser = @import("../netsurf.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

const NavigationKind = @import("root.zig").NavigationKind;
const NavigationHistoryEntry = @import("root.zig").NavigationHistoryEntry;
const NavigationTransition = @import("root.zig").NavigationTransition;
const NavigationCurrentEntryChangeEvent = @import("root.zig").NavigationCurrentEntryChangeEvent;

const NavigationEventTarget = @import("NavigationEventTarget.zig");

pub const prototype = *NavigationEventTarget;
proto: NavigationEventTarget = NavigationEventTarget{},

index: usize = 0,
// Need to be stable pointers, because Events can reference entries.
entries: std.ArrayListUnmanaged(*NavigationHistoryEntry) = .empty,
next_entry_id: usize = 0,

pub fn get_canGoBack(self: *const Navigation) bool {
    return self.index > 0;
}

pub fn get_canGoForward(self: *const Navigation) bool {
    return self.entries.items.len > self.index + 1;
}

pub fn currentEntry(self: *Navigation) *NavigationHistoryEntry {
    return self.entries.items[self.index];
}

pub fn get_currentEntry(self: *Navigation) *NavigationHistoryEntry {
    return self.currentEntry();
}

pub fn get_transition(_: *const Navigation) ?NavigationTransition {
    // For now, all transitions are just considered complete.
    return null;
}

const NavigationReturn = struct {
    committed: js.Promise,
    finished: js.Promise,
};

pub fn _back(self: *Navigation, page: *Page) !NavigationReturn {
    if (!self.get_canGoBack()) {
        return error.InvalidStateError;
    }

    const new_index = self.index - 1;
    const next_entry = self.entries.items[new_index];
    self.index = new_index;

    return self.navigate(next_entry.url, .{ .traverse = new_index }, page);
}

pub fn _entries(self: *const Navigation) []*NavigationHistoryEntry {
    return self.entries.items;
}

pub fn _forward(self: *Navigation, page: *Page) !NavigationReturn {
    if (!self.get_canGoForward()) {
        return error.InvalidStateError;
    }

    const new_index = self.index + 1;
    const next_entry = self.entries.items[new_index];
    self.index = new_index;

    return self.navigate(next_entry.url, .{ .traverse = new_index }, page);
}

// This is for after true navigation processing, where we need to ensure that our entries are up to date.
// This is only really safe to run in the `pageDoneCallback` where we can guarantee that the URL and NavigationKind are correct.
pub fn processNavigation(self: *Navigation, page: *Page) !void {
    const url = page.url.raw;
    const kind = page.session.navigation_kind;

    if (kind) |k| {
        switch (k) {
            .replace => {
                // When replacing, we just update the URL but the state is nullified.
                const entry = self.currentEntry();
                entry.url = url;
                entry.state = null;
            },
            .push => |state| {
                _ = try self.pushEntry(url, state, page, false);
            },
            .traverse, .reload => {},
        }
    } else {
        _ = try self.pushEntry(url, null, page, false);
    }
}

/// Pushes an entry into the Navigation stack WITHOUT actually navigating to it.
/// For that, use `navigate`.
pub fn pushEntry(self: *Navigation, _url: []const u8, state: ?[]const u8, page: *Page, dispatch: bool) !*NavigationHistoryEntry {
    const arena = page.session.arena;

    const url = try arena.dupe(u8, _url);

    // truncates our history here.
    if (self.entries.items.len > self.index + 1) {
        self.entries.shrinkRetainingCapacity(self.index + 1);
    }

    const index = self.entries.items.len;

    const id = self.next_entry_id;
    self.next_entry_id += 1;

    const id_str = try std.fmt.allocPrint(arena, "{d}", .{id});

    const entry = try arena.create(NavigationHistoryEntry);
    entry.* = NavigationHistoryEntry{
        .id = id_str,
        .key = id_str,
        .url = url,
        .state = state,
    };

    // we don't always have a current entry...
    const previous = if (self.entries.items.len > 0) self.currentEntry() else null;
    try self.entries.append(arena, entry);
    if (previous) |prev| {
        if (dispatch) {
            NavigationCurrentEntryChangeEvent.dispatch(self, prev, .push);
        }
    }

    self.index = index;

    return entry;
}

const NavigateOptions = struct {
    const NavigateOptionsHistory = enum {
        pub const ENUM_JS_USE_TAG = true;

        auto,
        push,
        replace,
    };

    state: ?js.Object = null,
    info: ?js.Object = null,
    history: NavigateOptionsHistory = .auto,
};

pub fn navigate(
    self: *Navigation,
    _url: ?[]const u8,
    kind: NavigationKind,
    page: *Page,
) !NavigationReturn {
    const arena = page.session.arena;
    const url = _url orelse return error.MissingURL;

    // https://github.com/WICG/navigation-api/issues/95
    //
    // These will only settle on same-origin navigation (mostly intended for SPAs).
    // It is fine (and expected) for these to not settle on cross-origin requests :)
    const committed = try page.js.createPromiseResolver(.page);
    const finished = try page.js.createPromiseResolver(.page);

    const new_url = try URL.parse(url, null);
    const is_same_document = try page.url.eqlDocument(&new_url, arena);

    switch (kind) {
        .push => |state| {
            if (is_same_document) {
                page.url = new_url;

                try committed.resolve({});
                // todo: Fire navigate event
                try finished.resolve({});

                _ = try self.pushEntry(url, state, page, true);
            } else {
                try page.navigateFromWebAPI(url, .{ .reason = .navigation }, kind);
            }
        },
        .traverse => |index| {
            self.index = index;

            if (is_same_document) {
                page.url = new_url;

                try committed.resolve({});
                // todo: Fire navigate event
                try finished.resolve({});
            } else {
                try page.navigateFromWebAPI(url, .{ .reason = .navigation }, kind);
            }
        },
        .reload => {
            try page.navigateFromWebAPI(url, .{ .reason = .navigation }, kind);
        },
        else => unreachable,
    }

    return .{
        .committed = committed.promise(),
        .finished = finished.promise(),
    };
}

pub fn _navigate(self: *Navigation, _url: []const u8, _opts: ?NavigateOptions, page: *Page) !NavigationReturn {
    const opts = _opts orelse NavigateOptions{};
    const json = if (opts.state) |state| state.toJson(page.session.arena) catch return error.DataClone else null;
    return try self.navigate(_url, .{ .push = json }, page);
}

pub const ReloadOptions = struct {
    state: ?js.Object = null,
    info: ?js.Object = null,
};

pub fn _reload(self: *Navigation, _opts: ?ReloadOptions, page: *Page) !NavigationReturn {
    const arena = page.session.arena;

    const opts = _opts orelse ReloadOptions{};
    const entry = self.currentEntry();
    if (opts.state) |state| {
        const previous = entry;
        entry.state = state.toJson(arena) catch return error.DataClone;
        NavigationCurrentEntryChangeEvent.dispatch(self, previous, .reload);
    }

    return self.navigate(entry.url, .reload, page);
}

pub const TraverseToOptions = struct {
    info: ?js.Object = null,
};

pub fn _traverseTo(self: *Navigation, key: []const u8, _opts: ?TraverseToOptions, page: *Page) !NavigationReturn {
    if (_opts != null) {
        log.debug(.browser, "not implemented", .{ .options = _opts });
    }

    for (self.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, key, entry.key)) {
            return try self.navigate(entry.url, .{ .traverse = i }, page);
        }
    }

    return error.InvalidStateError;
}

pub const UpdateCurrentEntryOptions = struct {
    state: js.Object,
};

pub fn _updateCurrentEntry(self: *Navigation, options: UpdateCurrentEntryOptions, page: *Page) !void {
    const arena = page.session.arena;

    const previous = self.currentEntry();
    self.currentEntry().state = options.state.toJson(arena) catch return error.DataClone;
    NavigationCurrentEntryChangeEvent.dispatch(self, previous, null);
}

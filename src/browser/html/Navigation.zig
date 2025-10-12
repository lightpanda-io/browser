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

const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventHandler = @import("../events/event.zig").EventHandler;

const parser = @import("../netsurf.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

pub const Interfaces = .{
    Navigation,
    NavigationActivation,
    NavigationHistoryEntry,
};

pub const prototype = *EventTarget;
base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .plain },

index: usize = 0,
entries: std.ArrayListUnmanaged(NavigationHistoryEntry) = .empty,
next_entry_id: usize = 0,
// TODO: key->index mapping

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationHistoryEntry
const NavigationHistoryEntry = struct {
    pub const prototype = *EventTarget;
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .plain },

    id: []const u8,
    key: []const u8,
    url: ?[]const u8,
    state: ?[]const u8,

    pub fn get_id(self: *const NavigationHistoryEntry) []const u8 {
        return self.id;
    }

    pub fn get_index(self: *const NavigationHistoryEntry, page: *Page) i32 {
        const navigation = page.session.navigation;
        for (navigation.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.id, self.id)) {
                return @intCast(i);
            }
        }

        return -1;
    }

    pub fn get_key(self: *const NavigationHistoryEntry) []const u8 {
        return self.key;
    }

    pub fn get_sameDocument(self: *const NavigationHistoryEntry, page: *Page) !bool {
        const _url = self.url orelse return false;
        const url = try URL.parse(_url, null);
        return page.url.eqlDocument(&url, page.arena);
    }

    pub fn get_url(self: *const NavigationHistoryEntry) ?[]const u8 {
        return self.url;
    }

    pub fn _getState(self: *const NavigationHistoryEntry, page: *Page) !?js.Value {
        if (self.state) |state| {
            return try js.Value.fromJson(page.js, state);
        } else {
            return null;
        }
    }

    pub fn navigate(entry: NavigationHistoryEntry, reload: enum { none, force }, page: *Page) !NavigationReturn {
        const arena = page.session.arena;
        const url = entry.url orelse return error.MissingURL;

        // https://github.com/WICG/navigation-api/issues/95
        //
        // These will only settle on same-origin navigation (mostly intended for SPAs).
        // It is fine (and expected) for these to not settle on cross-origin requests :)
        const committed = try page.js.createPromiseResolver(.page);
        const finished = try page.js.createPromiseResolver(.page);

        const new_url = try URL.parse(url, null);
        if (try page.url.eqlDocument(&new_url, arena) or reload == .force) {
            page.url = new_url;
            try committed.resolve({});

            // todo: Fire navigate event

            try finished.resolve({});
        } else {
            // TODO: Change to history
            try page.navigateFromWebAPI(url, .{ .reason = .history });
        }

        return .{
            .committed = committed.promise(),
            .finished = finished.promise(),
        };
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationActivation
const NavigationActivation = struct {
    const NavigationActivationType = enum {
        push,
        reload,
        replace,
        traverse,

        pub fn toString(self: NavigationActivationType) []const u8 {
            return @tagName(self);
        }
    };

    entry: NavigationHistoryEntry,
    from: ?NavigationHistoryEntry = null,
    type: NavigationActivationType,

    pub fn get_entry(self: *const NavigationActivation) NavigationHistoryEntry {
        return self.entry;
    }

    pub fn get_from(self: *const NavigationActivation) ?NavigationHistoryEntry {
        return self.from;
    }

    pub fn get_navigationType(self: *const NavigationActivation) NavigationActivationType {
        return self.type;
    }
};

pub fn get_canGoBack(self: *const Navigation) bool {
    return self.index > 0;
}

pub fn get_canGoForward(self: *const Navigation) bool {
    return self.entries.items.len > self.index + 1;
}

pub fn currentEntry(self: *Navigation) *NavigationHistoryEntry {
    return &self.entries.items[self.index];
}

pub fn get_currentEntry(self: *const Navigation) NavigationHistoryEntry {
    return self.entries.items[self.index];
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

    return next_entry.navigate(.none, page);
}

pub fn _entries(self: *const Navigation) []NavigationHistoryEntry {
    return self.entries.items;
}

pub fn _forward(self: *Navigation, page: *Page) !NavigationReturn {
    if (!self.get_canGoForward()) {
        return error.InvalidStateError;
    }

    const new_index = self.index + 1;
    const next_entry = self.entries.items[new_index];
    self.index = new_index;

    return next_entry.navigate(.none, page);
}

/// Pushes an entry into the Navigation stack WITHOUT actually navigating to it.
/// For that, use `navigate`.
pub fn pushEntry(self: *Navigation, _url: ?[]const u8, _opts: ?NavigateOptions, page: *Page) !NavigationHistoryEntry {
    const arena = page.session.arena;

    const options = _opts orelse NavigateOptions{};
    const url = if (_url) |u| try arena.dupe(u8, u) else null;

    // truncates our history here.
    if (self.entries.items.len > self.index + 1) {
        self.entries.shrinkRetainingCapacity(self.index + 1);
    }
    self.index = self.entries.items.len;

    const id = self.next_entry_id;
    self.next_entry_id += 1;

    const id_str = try std.fmt.allocPrint(arena, "{d}", .{id});

    const state: ?[]const u8 = blk: {
        if (options.state) |s| {
            break :blk s.toJson(arena) catch return error.DataClone;
        } else {
            break :blk null;
        }
    };

    const entry = NavigationHistoryEntry{
        .id = id_str,
        .key = id_str,
        .url = url,
        .state = state,
    };

    try self.entries.append(arena, entry);

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

pub fn _navigate(self: *Navigation, _url: []const u8, _opts: ?NavigateOptions, page: *Page) !NavigationReturn {
    const entry = try self.pushEntry(_url, _opts, page);
    return entry.navigate(.none, page);
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
        entry.state = state.toJson(arena) catch return error.DataClone;
    }

    return entry.navigate(.force, page);
}

pub fn _transition(_: *const Navigation) !NavigationReturn {
    unreachable;
}

pub fn _traverseTo(_: *const Navigation, _: []const u8) !NavigationReturn {
    unreachable;
}

pub const UpdateCurrentEntryOptions = struct {
    state: js.Object,
};

pub fn _updateCurrentEntry(self: *Navigation, options: UpdateCurrentEntryOptions, page: *Page) !void {
    const arena = page.session.arena;
    self.currentEntry().state = options.state.toJson(arena) catch return error.DataClone;
}

const testing = @import("../../testing.zig");
test "Browser: Navigation" {
    try testing.htmlRunner("html/navigation.html");
}

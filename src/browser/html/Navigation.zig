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

const Js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventHandler = @import("../events/event.zig").EventHandler;

const parser = @import("../netsurf.zig");

const Interfaces = .{
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
    index: usize,
    key: []const u8,
    url: ?[]const u8,
    same_document: bool,
    state: ?[]const u8,

    pub fn get_id(self: *const NavigationHistoryEntry) []const u8 {
        return self.id;
    }

    pub fn get_index(self: *const NavigationHistoryEntry) usize {
        return self.index;
    }

    pub fn get_key(self: *const NavigationHistoryEntry) []const u8 {
        return self.key;
    }

    pub fn get_sameDocument(self: *const NavigationHistoryEntry) bool {
        return self.same_document;
    }

    pub fn get_url(self: *const NavigationHistoryEntry) ?[]const u8 {
        return self.url;
    }

    pub fn _getState(self: *const NavigationHistoryEntry, page: *Page) !?Js.Value {
        if (self.state) |state| {
            return try Js.Value.fromJson(page.main_context, state);
        } else {
            return null;
        }
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

pub fn get_currentEntry(_: *const Navigation) NavigationHistoryEntry {
    // TODO
    unreachable;
}

const NavigationReturn = struct {
    comitted: Js.Promise,
    finished: Js.Promise,
};

pub fn _back(_: *const Navigation) !NavigationReturn {
    unreachable;
}

pub fn _entries(self: *const Navigation) []NavigationHistoryEntry {
    return self.entries.items;
}

pub fn _forward(_: *const Navigation) !NavigationReturn {
    unreachable;
}

const NavigateOptions = struct {
    const NavigateOptionsHistory = enum {
        auto,
        push,
        replace,
    };

    state: ?Js.Object = null,
    info: ?Js.Object = null,
    history: NavigateOptionsHistory = .auto,
};

pub fn _navigate(self: *Navigation, _url: []const u8, _opts: ?NavigateOptions, page: *Page) !NavigationReturn {
    const arena = page.session.arena;

    const options = _opts orelse NavigateOptions{};
    const url = try arena.dupe(u8, _url);

    // TODO: handle push history NotSupportedError.

    const index = self.entries.items.len;
    const id = self.next_entry_id;
    self.next_entry_id += 1;

    const id_str = try std.fmt.allocPrint(arena, "{d}", .{id});

    const state: ?[]const u8 = blk: {
        if (options.state) |s| {
            break :blk try s.toJson(arena);
        } else {
            break :blk null;
        }
    };

    const entry = NavigationHistoryEntry{
        .id = id_str,
        .index = index,
        .same_document = false,
        .url = url,
        .key = id_str,
        .state = state,
    };

    try self.entries.append(arena, entry);

    // https://github.com/WICG/navigation-api/issues/95
    //
    // These will only settle on same-origin navigation (mostly intended for SPAs).
    // It is fine (and expected) for these to not settle on cross-origin requests :)
    const committed = try page.main_context.createPersistentPromiseResolver(.page);
    const finished = try page.main_context.createPersistentPromiseResolver(.page);

    if (entry.same_document) {
        page.url = try URL.parse(url, null);
        try committed.resolve(void);

        // todo: Fire navigate event
        //

    } else {
        page.navigateFromWebAPI(url, .{ .reason = .navigation });
    }

    return .{
        .comitted = committed,
        .finished = finished,
    };
}

// const testing = @import("../../testing.zig");
// test "Browser: Navigation" {
//     try testing.htmlRunner("html/navigation.html");
// }

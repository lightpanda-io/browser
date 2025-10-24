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

const Navigation = @import("Navigation.zig");
const NavigationEventTarget = @import("NavigationEventTarget.zig");

pub const Interfaces = .{
    Navigation,
    NavigationEventTarget,
    NavigationActivation,
    NavigationTransition,
    NavigationHistoryEntry,
};

pub const NavigationType = enum {
    pub const ENUM_JS_USE_TAG = true;

    push,
    replace,
    traverse,
    reload,
};

pub const NavigationKind = union(NavigationType) {
    push: ?[]const u8,
    replace,
    traverse: usize,
    reload,
};

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationHistoryEntry
pub const NavigationHistoryEntry = struct {
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
        for (navigation.entries.items, 0..) |entry, i| {
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
        return page.url.eqlDocument(&url, page.call_arena);
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
};

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationActivation
pub const NavigationActivation = struct {
    const NavigationActivationType = enum {
        pub const ENUM_JS_USE_TAG = true;

        push,
        reload,
        replace,
        traverse,
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

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationTransition
pub const NavigationTransition = struct {
    finished: js.Promise,
    from: NavigationHistoryEntry,
    navigation_type: NavigationActivation.NavigationActivationType,
};

const Event = @import("../events/event.zig").Event;

pub const NavigationCurrentEntryChangeEvent = struct {
    pub const prototype = *Event;
    pub const union_make_copy = true;

    pub const EventInit = struct {
        from: *NavigationHistoryEntry,
        navigationType: ?NavigationType = null,
    };

    proto: parser.Event,
    from: *NavigationHistoryEntry,
    navigation_type: ?NavigationType,

    pub fn constructor(event_type: []const u8, opts: EventInit) !NavigationCurrentEntryChangeEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);

        try parser.eventInit(event, event_type, .{});
        parser.eventSetInternalType(event, .navigation_current_entry_change_event);

        return .{
            .proto = event.*,
            .from = opts.from,
            .navigation_type = opts.navigationType,
        };
    }

    pub fn get_from(self: *NavigationCurrentEntryChangeEvent) *NavigationHistoryEntry {
        return self.from;
    }

    pub fn get_navigationType(self: *const NavigationCurrentEntryChangeEvent) ?NavigationType {
        return self.navigation_type;
    }

    pub fn dispatch(navigation: *Navigation, from: *NavigationHistoryEntry, typ: ?NavigationType) void {
        log.debug(.script_event, "dispatch event", .{
            .type = "currententrychange",
            .source = "navigation",
        });

        var evt = NavigationCurrentEntryChangeEvent.constructor(
            "currententrychange",
            .{ .from = from, .navigationType = typ },
        ) catch |err| {
            log.err(.app, "event constructor error", .{
                .err = err,
                .type = "currententrychange",
                .source = "navigation",
            });

            return;
        };

        _ = parser.eventTargetDispatchEvent(
            @as(*parser.EventTarget, @ptrCast(navigation)),
            &evt.proto,
        ) catch |err| {
            log.err(.app, "dispatch event error", .{
                .err = err,
                .type = "currententrychange",
                .source = "navigation",
            });
        };
    }
};

const testing = @import("../../testing.zig");
test "Browser: Navigation" {
    try testing.htmlRunner("html/navigation/navigation.html");
    try testing.htmlRunner("html/navigation/navigation_currententrychange.html");
}

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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Navigation = @import("Navigation.zig");
const NavigationEventTarget = @import("NavigationEventTarget.zig");
const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");

pub const NavigationType = enum {
    push,
    replace,
    traverse,
    reload,
};

pub const NavigationKind = union(NavigationType) {
    push: ?[]const u8,
    replace: ?[]const u8,
    traverse: usize,
    reload,
};

pub const NavigationState = struct {
    source: enum { history, navigation },
    value: ?[]const u8,
};

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationActivation
pub const NavigationActivation = struct {
    entry: NavigationHistoryEntry,
    from: ?NavigationHistoryEntry = null,
    type: NavigationType,

    pub fn get_entry(self: *const NavigationActivation) NavigationHistoryEntry {
        return self.entry;
    }

    pub fn get_from(self: *const NavigationActivation) ?NavigationHistoryEntry {
        return self.from;
    }

    pub fn get_navigationType(self: *const NavigationActivation) NavigationType {
        return self.type;
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationTransition
pub const NavigationTransition = struct {
    finished: js.Promise,
    from: NavigationHistoryEntry,
    navigation_type: NavigationType,
};

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

const js = @import("../../js/js.zig");

const AbortSignal = @import("../AbortSignal.zig");
const NavigateEvent = @import("../event/NavigateEvent.zig");
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

    pub fn toNavigationType(self: NavigationKind) NavigationType {
        return std.meta.activeTag(self);
    }
};

pub const NavigationState = struct {
    source: enum { history, navigation },
    value: ?[]const u8,
};

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationTransition
pub const NavigationTransition = struct {
    finished: js.Promise.Global,
    from: NavigationHistoryEntry,
    navigation_type: NavigationType,
};

// Frame._ongoing_navigate. Aborted by a new navigation, window.stop() or
// canceling the event.
pub const OngoingNavigation = struct {
    signal: *AbortSignal,
    // Only set while the event is being dispatched
    event: ?*NavigateEvent = null,
    // Promises of navigation.navigate()/reload()/traverseTo()/back()/forward()
    committed: ?js.PromiseResolver.Global = null,
    finished: ?js.PromiseResolver.Global = null,
    committed_same_document: bool = false,

    pub fn releasePromises(self: *OngoingNavigation) void {
        if (self.committed) |c| {
            c.release();
            self.committed = null;
        }
        if (self.finished) |f| {
            f.release();
            self.finished = null;
        }
    }
};

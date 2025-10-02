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

const js = @import("../js/js.zig");
const parser = @import("../netsurf.zig");
const EventTarget = @import("../dom/event_target.zig").EventTarget;

// https://drafts.csswg.org/cssom-view/#the-mediaquerylist-interface
pub const MediaQueryList = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    // This is not safe as it relies on a structure layout that isn't guaranteed
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .media_query_list },

    matches: bool,
    media: []const u8,

    pub fn get_matches(self: *const MediaQueryList) bool {
        return self.matches;
    }

    pub fn get_media(self: *const MediaQueryList) []const u8 {
        return self.media;
    }

    pub fn _addListener(_: *const MediaQueryList, _: js.Function) void {}

    pub fn _removeListener(_: *const MediaQueryList, _: js.Function) void {}
};

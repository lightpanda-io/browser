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

const parser = @import("../netsurf.zig");
const Event = @import("../events/event.zig").Event;

const DOMException = @import("../dom/exceptions.zig").DOMException;

pub const ProgressEvent = struct {
    pub const prototype = *Event;
    pub const Exception = DOMException;
    pub const union_make_copy = true;

    pub const EventInit = struct {
        lengthComputable: bool = false,
        loaded: u64 = 0,
        total: u64 = 0,
    };

    proto: parser.Event,
    lengthComputable: bool,
    loaded: u64 = 0,
    total: u64 = 0,

    pub fn constructor(event_type: []const u8, opts: ?EventInit) !ProgressEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{});
        try parser.eventSetInternalType(event, .progress_event);

        const o = opts orelse EventInit{};

        return .{
            .proto = event.*,
            .lengthComputable = o.lengthComputable,
            .loaded = o.loaded,
            .total = o.total,
        };
    }

    pub fn get_lengthComputable(self: *const ProgressEvent) bool {
        return self.lengthComputable;
    }

    pub fn get_loaded(self: *const ProgressEvent) u64 {
        return self.loaded;
    }

    pub fn get_total(self: *const ProgressEvent) u64 {
        return self.total;
    }
};

const testing = @import("../../testing.zig");
test "Browser: XHR.ProgressEvent" {
    try testing.htmlRunner("xhr/progress_event.html");
}

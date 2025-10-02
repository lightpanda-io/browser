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

pub const Interfaces = .{
    ResizeObserver,
};

// WEB IDL https://drafts.csswg.org/resize-observer/#resize-observer-interface
pub const ResizeObserver = struct {
    pub fn constructor(cbk: js.Function) ResizeObserver {
        _ = cbk;
        return .{};
    }

    pub fn _observe(self: *const ResizeObserver, element: *parser.Element, options_: ?Options) void {
        _ = self;
        _ = element;
        _ = options_;
        return;
    }

    pub fn _unobserve(self: *const ResizeObserver, element: *parser.Element) void {
        _ = self;
        _ = element;
        return;
    }

    // TODO
    pub fn _disconnect(self: *ResizeObserver) void {
        _ = self;
    }
};

const Options = struct {
    box: []const u8,
};

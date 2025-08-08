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
const parser = @import("../netsurf.zig");
const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;

// WEB IDL https://dom.spec.whatwg.org/#interface-shadowroot
pub const ShadowRoot = struct {
    pub const prototype = *parser.DocumentFragment;
    pub const subtype = .node;

    mode: Mode,
    host: *parser.Element,
    proto: *parser.DocumentFragment,

    pub const Mode = enum {
        open,
        closed,
    };

    pub fn get_host(self: *const ShadowRoot) !ElementUnion {
        return Element.toInterface(self.host);
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.ShadowRoot" {
    defer testing.reset();

    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html =
        \\ <div id=conflict>nope</div>
    });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "const div1 = document.createElement('div');", null },
        .{ "let sr1 = div1.attachShadow({mode: 'open'})", null },
        .{ "sr1.host == div1", "true" },
        .{ "div1.attachShadow({mode: 'open'}) == sr1", "true" },
        .{ "div1.shadowRoot == sr1", "true" },

        .{ "try { div1.attachShadow({mode: 'closed'}) } catch (e) { e }", "Error: NotSupportedError" },

        .{ " sr1.append(document.createElement('div'))", null },
        .{ " sr1.append(document.createElement('span'))", null },
        .{ "sr1.childElementCount", "2" },
        // re-attaching clears it
        .{ "div1.attachShadow({mode: 'open'}) == sr1", "true" },
        .{ "sr1.childElementCount", "0" },
    }, .{});

    try runner.testCases(&.{
        .{ "const div2 = document.createElement('di2');", null },
        .{ "let sr2 = div2.attachShadow({mode: 'closed'})", null },
        .{ "sr2.host == div2", "true" },
        .{ "div2.shadowRoot", "null" }, // null when attached with 'closed'
    }, .{});

    try runner.testCases(&.{
        .{ "sr2.getElementById('conflict')", "null" },
        .{ "const n1 = document.createElement('div')", null },
        .{ "n1.id = 'conflict'", null},
        .{ "sr2.append(n1)", null},
        .{ "sr2.getElementById('conflict') == n1", "true" },
    }, .{});
}
